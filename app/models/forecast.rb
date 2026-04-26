class Forecast < ApplicationRecord
  include Monetizable

  monetize :amount

  attribute :value_strategy, :string, default: "fixed_amount"

  belongs_to :family
  belongs_to :account
  belongs_to :category, optional: true

  has_many :taggings, as: :taggable, dependent: :destroy
  has_many :tags, through: :taggings
  has_many :materializations, class_name: "Forecast::Materialization", dependent: :destroy

  enum :kind, { income: "income", expense: "expense" }, validate: true
  enum :schedule, { one_time: "one_time", monthly: "monthly", yearly: "yearly" }, validate: true
  enum :value_strategy, { fixed_amount: "fixed_amount", percentage_of_balance: "percentage_of_balance" }, validate: true

  scope :alphabetically, -> { order(:name) }
  scope :for_accounts, ->(account_ids) {
    return all if account_ids.blank?

    where(account_id: account_ids)
  }

  validates :name, :currency, :kind, :schedule, :value_strategy, presence: true
  validates :amount, presence: true, numericality: { greater_than: 0 }, if: :fixed_amount?
  validates :annual_rate, presence: true, numericality: { greater_than: 0 }, if: :percentage_of_balance?
  validates :annual_increase_rate, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :day_of_month, inclusion: { in: 1..31 }, if: -> { monthly? && !spread_across_month? }
  validates :occurs_on, presence: true, if: -> { one_time? || yearly? }
  validate :date_range_is_valid
  validate :account_belongs_to_family
  validate :category_belongs_to_family
  validate :account_supports_manual_entries
  validate :percentage_of_balance_settings_are_valid
  validate :spread_across_month_settings_are_valid

  before_validation :assign_family_from_account

  def signed_projection_amount(target_currency:, occurrence_date:, balance_amount: nil)
    projected_amount = projection_amount(
      target_currency: target_currency,
      occurrence_date: occurrence_date,
      balance_amount: balance_amount
    )

    income? ? projected_amount : -projected_amount
  end

  def entry_amount(occurrence_date: Date.current, balance_amount: nil)
    projected_amount = projection_amount(
      target_currency: currency,
      occurrence_date: occurrence_date,
      balance_amount: balance_amount
    )

    income? ? -projected_amount : projected_amount
  end

  def converted_amount(target_currency, occurrence_date: Date.current)
    amount_money.exchange_to(
      target_currency,
      date: occurrence_date,
      fallback_rate: latest_exchange_rate_for(target_currency)
    )
  end

  def occurrence_dates_between(start_date:, end_date:, from_date: Date.current)
    return [] if end_date < start_date

    effective_start = [ start_date, from_date ].compact.max
    effective_end = end_date
    return [] if effective_end < effective_start

    dates = if one_time?
      one_time_occurrence_dates(effective_start, effective_end)
    elsif yearly?
      yearly_occurrence_dates(effective_start, effective_end)
    elsif spread_across_month?
      distributed_occurrence_dates(effective_start, effective_end)
    else
      monthly_occurrence_dates(effective_start, effective_end)
    end

    dates - materialized_dates
  end

  def projection_events_between(target_currency:, start_date:, end_date:, from_date: Date.current)
    if spread_across_month?
      distributed_projection_events(
        target_currency: target_currency,
        start_date: start_date,
        end_date: end_date,
        from_date: from_date
      )
    else
      occurrence_dates_between(
        start_date: start_date,
        end_date: end_date,
        from_date: from_date
      ).map do |occurrence_date|
        [
          occurrence_date,
          signed_projection_amount(target_currency: target_currency, occurrence_date: occurrence_date)
        ]
      end
    end
  end

  def projection_occurrence_dates_between(start_date:, end_date:, from_date: Date.current)
    if spread_across_month?
      distributed_occurrence_dates(start_date, end_date, from_date: from_date)
    else
      occurrence_dates_between(start_date: start_date, end_date: end_date, from_date: from_date)
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
    return nil if spread_across_month?

    due_dates = if one_time?
      occurs_on.present? && occurs_on <= today ? [ occurs_on ] : []
    elsif yearly?
      yearly_occurrence_dates(effective_start_date(today.beginning_of_year), today)
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
        amount: entry_amount(occurrence_date: occurrence_date),
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
    elsif yearly?
      "Yearly on #{occurs_on&.strftime("%b %-d")}"
    elsif spread_across_month?
      "Monthly throughout month"
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

    def projection_amount(target_currency:, occurrence_date:, balance_amount: nil)
      if percentage_of_balance?
        balance = balance_amount || current_balance_amount(target_currency)
        balance * periodic_projection_rate
      else
        converted_amount(target_currency, occurrence_date: occurrence_date).amount * annual_increase_multiplier(occurrence_date)
      end
    end

    def one_time_occurrence_dates(start_date, end_date)
      return [] if occurs_on.blank?
      return [] unless occurs_on.between?(start_date, end_date)

      [ occurs_on ]
    end

    def yearly_occurrence_dates(start_date, end_date)
      return [] if occurs_on.blank?

      cursor_year = effective_start_date(start_date).year
      limit = effective_end_date(end_date)
      return [] if limit < start_date

      dates = []

      while cursor_year <= limit.year
        day_of_month = [ occurs_on.day, Time.days_in_month(occurs_on.month, cursor_year) ].min
        occurrence_date = Date.new(cursor_year, occurs_on.month, day_of_month)

        if occurrence_date >= start_date && occurrence_date <= limit
          dates << occurrence_date
        end

        cursor_year += 1
      end

      dates
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

    def distributed_occurrence_dates(start_date, end_date, from_date: start_date)
      distributed_projection_events(
        target_currency: currency,
        start_date: start_date,
        end_date: end_date,
        from_date: from_date
      ).map(&:first)
    end

    def distributed_projection_events(target_currency:, start_date:, end_date:, from_date:)
      effective_start = [ start_date, from_date ].compact.max
      limit = effective_end_date(end_date)
      return [] if limit < effective_start

      cursor = effective_start_date(start_date).beginning_of_month
      events = []

      while cursor <= limit
        month_dates = (cursor..cursor.end_of_month).to_a
        active_dates = month_dates.select do |date|
          date >= effective_start_date(cursor) && date <= effective_end_date(cursor.end_of_month)
        end
        visible_dates = active_dates.select { |date| date >= effective_start && date <= limit }

        if active_dates.any?
          monthly_amount = signed_projection_amount(target_currency: target_currency, occurrence_date: cursor)
          prorated_amount = monthly_amount * active_dates.size / month_dates.size

          events.concat(distribute_amount(prorated_amount, active_dates, visible_dates))
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

    def current_balance_amount(target_currency)
      account.balance_money.exchange_to(
        target_currency,
        fallback_rate: ExchangeRate.latest_rate(from_currency: account.currency, to_currency: target_currency)
      ).amount
    end

    def annual_increase_multiplier(occurrence_date)
      return BigDecimal("1") if annual_increase_rate.blank? || annual_increase_rate.zero?

      (BigDecimal("1") + annual_increase_rate.to_d / 100) ** completed_years_since(growth_reference_date, occurrence_date)
    end

    def growth_reference_date
      @growth_reference_date ||= starts_on || occurs_on || created_at&.to_date || Date.current
    end

    def completed_years_since(start_date, end_date)
      return 0 if start_date.blank? || end_date <= start_date

      years = end_date.year - start_date.year
      years -= 1 if end_date < start_date.advance(years: years)
      years
    end

    def periodic_projection_rate
      annual_rate.to_d / 100 / periodic_projection_divisor
    end

    def periodic_projection_divisor
      return BigDecimal("1") if yearly?
      return BigDecimal("12") if monthly?

      raise ArgumentError, "Account-value forecasts must be monthly or yearly"
    end

    def percentage_of_balance_settings_are_valid
      return unless percentage_of_balance?

      errors.add(:schedule, "must be monthly or yearly for account-value forecasts") unless monthly? || yearly?
      errors.add(:annual_increase_rate, "cannot be combined with account-value forecasts") if annual_increase_rate.to_d.positive?
    end

    def spread_across_month_settings_are_valid
      return unless spread_across_month?

      errors.add(:schedule, "must be monthly when spread across month is enabled") unless monthly?
      errors.add(:value_strategy, "must be fixed amount when spread across month is enabled") unless fixed_amount?
    end
end
