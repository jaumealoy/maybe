class AddSpreadAcrossMonthToForecasts < ActiveRecord::Migration[7.2]
  def change
    add_column :forecasts, :spread_across_month, :boolean, default: false, null: false
  end
end
