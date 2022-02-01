class InitialSchema < ActiveRecord::Migration
  def change
    create_table :categories do |t|
      t.string :name, null: false, limit: 64
      t.string :slug, null: false, limit: 32

      t.timestamps null: false
    end
    add_index :categories, :name, unique: true
    add_index :categories, :slug, unique: true

    create_table :posts do |t|
      t.integer :category_id, null: false
      t.string :postname, null: false
      t.string :title, null: false, limit: 124
      t.text :body, null: false
      t.string :thumbnail, null: false

      t.timestamps null: false
    end
    add_foreign_key :posts, :categories
    add_index :posts, :postname, unique: true
  end
end
