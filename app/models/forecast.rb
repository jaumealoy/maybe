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
  enum :schedule, { one_time: "one_time", monthly: "monthly" }, validate: true

  scope :alphabetically, -> { order(:name) }
  scope :for_accounts, ->(account_ids) {
    return all if account_ids.blank?

    where(account_id: account_ids)
  }

  validates :name, :amount, :currency, :kind, :schedule, presence: true
  validates :amount, numericality: { greater_than: 0 }
  validates :day_of_month, inclusion: { in: 1..31 }, if: :monthly?
  validates :occurs_on, presence: true, if: :one_time?
  validate :date_range_is_valid
  validate :account_belongs_to_family
  validate :category_belongs_to_family
  validate :account_supports_manual_entries

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

    effective_start = [start_date, from_date].compact.max
    effective_end = end_date
    return [] if effective_end < effective_start

    dates = if one_time?
      one_time_occurrence_dates(effective_start, effective_end)
    else
      monthly_occurrence_dates(effective_start, effective_end)
    end

    dates - materialized_dates
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

    due_dates = if one_time?
      occurs_on.present? && occurs_on <= today ? [ occurs_on ] : []
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

    def materialized_dates
      @materialized_dates ||= materializations.pluck(:occurrence_date)
    end

    def latest_exchange_rate_for(target_currency)
      return 1 if currency == target_currency

      ExchangeRate.where(from_currency: currency, to_currency: target_currency).order(date: :desc).pick(:rate) || 1
    end
end
