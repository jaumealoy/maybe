class Forecast::Materialization < ApplicationRecord
  belongs_to :forecast
  belongs_to :entry

  validates :occurrence_date, presence: true, uniqueness: { scope: :forecast_id }
end
