class CreateForecastAccountSets < ActiveRecord::Migration[7.2]
  def change
    create_table :forecast_account_sets, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.jsonb :account_ids, null: false, default: []
      t.timestamps
    end

    add_index :forecast_account_sets, [ :family_id, :name ], unique: true
  end
end
