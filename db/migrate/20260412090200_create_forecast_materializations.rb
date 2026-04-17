class CreateForecastMaterializations < ActiveRecord::Migration[7.2]
  def change
    create_table :forecast_materializations, id: :uuid do |t|
      t.references :forecast, null: false, foreign_key: true, type: :uuid
      t.references :entry, null: false, foreign_key: true, type: :uuid
      t.date :occurrence_date, null: false
      t.timestamps
    end

    add_index :forecast_materializations, [ :forecast_id, :occurrence_date ], unique: true, name: :index_forecast_materializations_on_forecast_and_occurrence
  end
end
