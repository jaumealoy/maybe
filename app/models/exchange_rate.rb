class ExchangeRate < ApplicationRecord
  include Provided

  validates :from_currency, :to_currency, :date, :rate, presence: true
  validates :date, uniqueness: { scope: %i[from_currency to_currency] }

  def self.latest_rate(from_currency:, to_currency:)
    return 1 if from_currency == to_currency

    where(from_currency:, to_currency:).order(date: :desc).pick(:rate) || 1
  end
end
