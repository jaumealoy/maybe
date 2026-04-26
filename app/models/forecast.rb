class Forecast < ApplicationRecord
  include Monetizable

  monetize :amount

  belongs_to :family
  belongs_to :account
  belongs_to :category, optional: true

  has_many :taggings, as: :taggable, dependent: :destroy
  has_many :tags, through: :taggings
  has_many :materializations, class_name: "Forecast::Materialization", dependent: :destroy

  enum :kind, { income: "income", expense: "expense" }, validate: true
  enum :schedule, { one_time: "one_time", monthly: "monthly", annual: "annual" }, validate: true

  scope :alphabetically, -> { order(:name) }
  scope :for_accounts, ->(account_ids) {
    return all if account_ids.blank?

    where(account_id: account_ids)
  }

  validates :name, :amount, :currency, :kind, :schedule, presence: true
  validates :amount, numericality: { greater_than: 0 }
  validates :day_of_month, inclusion: { in: 1..31 }, if: -> { monthly? && !spread_across_month? }
  validates :occurs_on, presence: true, if: :one_time?
  validates :starts_on, presence: true, if: :annual?
  validate :date_range_is_valid
  validate :account_belongs_to_family
  validate :category_belongs_to_family
  validate :account_supports_manual_entries
  validate :spread_across_month_requires_monthly_schedule

  before_validation :assign_family_from_account

  def signed_projection_amount
    income? ? amount : -amount
  end

  def entry_amount
    income? ? -amount : amount
  end

  def converted_amount(target_currency)
    amount_money.exchange_to(target_currency, fallback_rate: latest_exchange_rate_for(target_currency))
  end

  def occurrence_dates_between(start_date:, end_date:, from_date: Date.current)
    return [] if end_date < start_date

    effective_start = [ start_date, from_date ].compact.max
    effective_end = end_date
    return [] if effective_end < effective_start

    dates = if one_time?
      one_time_occurrence_dates(effective_start, effective_end)
    elsif monthly? && spread_across_month?
      distributed_occurrence_dates(effective_start, effective_end)
    elsif annual?
      annual_occurrence_dates(effective_start, effective_end)
    else
      monthly_occurrence_dates(effective_start, effective_end)
    end

    dates - materialized_dates
  end

  def projection_events_between(target_currency:, start_date:, end_date:, from_date: Date.current)
    converted_projection_amount = signed_projection_amount(target_currency)

    if monthly? && spread_across_month?
      distributed_projection_events(
        amount: converted_projection_amount,
        start_date: start_date,
        end_date: end_date,
        from_date: from_date
      )
    else
      occurrence_dates_between(
        start_date: start_date,
        end_date: end_date,
        from_date: from_date
      ).map { |occurrence_date| [ occurrence_date, converted_projection_amount ] }
    end
  end

  def next_occurrence_date(from_date: Date.current)
    occurrence_dates_between(
      start_date: from_date,
      end_date: effective_end_date(from_date + 5.years),
      from_date: from_date
    ).min
  end

  def materializable_occurrence_date(today: Date.current)
    return nil unless manual_entry_account?
    return nil if monthly? && spread_across_month?

    due_dates = if one_time?
      occurs_on.present? && occurs_on <= today ? [ occurs_on ] : []
    elsif annual?
      annual_occurrence_dates(effective_start_date(today.beginning_of_year), today)
    else
      monthly_occurrence_dates(effective_start_date(today.beginning_of_month), today)
    end

    (due_dates - materialized_dates).max
  end

  def materialize!(occurrence_date:)
    transaction do
      entry = account.entries.create!(
        name: name,
        date: occurrence_date,
        amount: entry_amount,
        currency: currency,
        entryable: Transaction.new(
          category: category,
          kind: "standard",
          tag_ids: tags.ids
        )
      )

      materializations.create!(occurrence_date: occurrence_date, entry: entry)
      entry
    end
  end

  def schedule_label
    if one_time?
      "One time"
    elsif monthly? && spread_across_month?
      "Monthly throughout month"
    elsif annual?
      starts_on.present? ? "Annual on #{starts_on.strftime("%B")} #{starts_on.day}" : "Annual"
    else
      "Monthly on day #{day_of_month}"
    end
  end

  private
    def assign_family_from_account
      self.family ||= account&.family
    end

    def date_range_is_valid
      if starts_on.present? && ends_on.present? && starts_on > ends_on
        errors.add(:starts_on, "must be on or before the end date")
      end

      return unless one_time? && occurs_on.present?

      if starts_on.present? && occurs_on < starts_on
        errors.add(:occurs_on, "must be on or after the start date")
      end

      if ends_on.present? && occurs_on > ends_on
        errors.add(:occurs_on, "must be on or before the end date")
      end
    end

    def account_belongs_to_family
      return if account.blank? || family.blank?
      return if account.family_id == family_id

      errors.add(:account, "must belong to the same family")
    end

    def category_belongs_to_family
      return if category.blank? || family.blank?
      return if category.family_id == family_id

      errors.add(:category, "must belong to the same family")
    end

    def account_supports_manual_entries
      return if account.blank?
      return if manual_entry_account?

      errors.add(:account, "must be a manual account")
    end

    def manual_entry_account?
      account&.plaid_account_id.nil?
    end

    def effective_start_date(default_date)
      [ starts_on, default_date ].compact.max
    end

    def effective_end_date(default_date)
      [ ends_on, default_date ].compact.min
    end

    def one_time_occurrence_dates(start_date, end_date)
      return [] if occurs_on.blank?
      return [] unless occurs_on.between?(start_date, end_date)

      [ occurs_on ]
    end

    def monthly_occurrence_dates(start_date, end_date)
      cursor = effective_start_date(start_date).beginning_of_month
      limit = effective_end_date(end_date)
      return [] if limit < cursor

      dates = []
      while cursor <= limit
        occurrence = [ cursor.end_of_month.day, day_of_month ].min
        occurrence_date = cursor.change(day: occurrence)

        if occurrence_date >= start_date && occurrence_date <= limit
          dates << occurrence_date
        end

        cursor = cursor.next_month.beginning_of_month
      end

      dates
    end

    def distributed_occurrence_dates(start_date, end_date)
      distributed_projection_events(
        amount: signed_projection_amount(currency),
        start_date: start_date,
        end_date: end_date,
        from_date: start_date
      ).map(&:first)
    end

    def annual_occurrence_dates(start_date, end_date)
      return [] if starts_on.blank?

      effective_start = effective_start_date(start_date)
      limit = effective_end_date(end_date)
      return [] if limit < effective_start

      (effective_start.year..limit.year).filter_map do |year|
        occurrence_date = annual_occurrence_date_for(year)
        occurrence_date if occurrence_date >= effective_start && occurrence_date <= limit
      end
    end

    def annual_occurrence_date_for(year)
      occurrence_month = Date.new(year, starts_on.month, 1)
      day = [ occurrence_month.end_of_month.day, starts_on.day ].min

      occurrence_month.change(day: day)
    end

    def distributed_projection_events(amount:, start_date:, end_date:, from_date:)
      effective_start = [ start_date, from_date ].compact.max
      limit = effective_end_date(end_date)
      return [] if limit < effective_start

      cursor = effective_start_date(start_date).beginning_of_month
      events = []

      while cursor <= limit
        month_start = [ cursor, effective_start_date(cursor) ].compact.max
        month_end = [ cursor.end_of_month, effective_end_date(cursor.end_of_month) ].compact.min

        if month_start <= month_end
          all_dates = (month_start..month_end).to_a
          visible_dates = all_dates.select { |date| date >= effective_start && date <= limit }

          events.concat(distribute_amount(amount, all_dates, visible_dates))
        end

        cursor = cursor.next_month.beginning_of_month
      end

      events
    end

    def distribute_amount(amount, all_dates, visible_dates)
      return [] if all_dates.empty? || visible_dates.empty?

      daily_amount = amount / all_dates.size
      emitted_dates = []

      all_dates.each_with_index.with_object([]) do |(date, index), result|
        allocated_amount = index == all_dates.size - 1 ? amount - emitted_dates.sum : daily_amount
        emitted_dates << allocated_amount
        result << [ date, allocated_amount ] if visible_dates.include?(date)
      end
    end

    def materialized_dates
      @materialized_dates ||= if materializations.loaded?
        materializations.map(&:occurrence_date)
      else
        materializations.pluck(:occurrence_date)
      end
    end

    def latest_exchange_rate_for(target_currency)
      ExchangeRate.latest_rate(from_currency: currency, to_currency: target_currency)
    end

    def signed_projection_amount(target_currency)
      converted_amount(target_currency).amount.then { |converted_amount| income? ? converted_amount : -converted_amount }
    end

    def spread_across_month_requires_monthly_schedule
      return unless spread_across_month? && !monthly?

      errors.add(:spread_across_month, "is only available for monthly forecasts")
    end
end
