class AddVariableSettingsToForecasts < ActiveRecord::Migration[7.2]
  def change
    change_column_null :forecasts, :amount, true

    add_column :forecasts, :value_strategy, :string, default: "fixed_amount", null: false
    add_column :forecasts, :annual_rate, :decimal, precision: 8, scale: 4
    add_column :forecasts, :annual_increase_rate, :decimal, precision: 8, scale: 4
  end
end
