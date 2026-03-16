class CreateDeadlockModels < ActiveRecord::Migration[4.2]
  def change
    create_table :deadlock_alphas do |t|
      t.string :name
      t.integer :sequential_id, null: false
      t.timestamps null: false
    end

    add_index :deadlock_alphas, :sequential_id, unique: true

    create_table :deadlock_beta do |t|
      t.string :name
      t.integer :sequential_id, null: false
      t.timestamps null: false
    end

    add_index :deadlock_beta, :sequential_id, unique: true
  end
end
