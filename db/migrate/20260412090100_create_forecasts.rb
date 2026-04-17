class CreateForecasts < ActiveRecord::Migration[7.2]
  def change
    create_table :forecasts, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :account, null: false, foreign_key: true, type: :uuid
      t.references :category, null: true, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.string :kind, null: false
      t.string :schedule, null: false
      t.date :occurs_on
      t.integer :day_of_month
      t.date :starts_on
      t.date :ends_on
      t.timestamps
    end

    add_index :forecasts, [ :family_id, :account_id ]
    add_index :forecasts, [ :family_id, :schedule ]
  end
end
