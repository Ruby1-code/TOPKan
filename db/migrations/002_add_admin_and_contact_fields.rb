Sequel.migration do
  up do
    alter_table(:people) do
      add_column :admin, TrueClass, null: false, default: false
      add_column :telephone1, String, size: 20
      add_column :sNumber, Integer
      add_column :sName, String, size: 50
      add_column :comments, String, size: 500
    end

    # Keep the existing login usable as an administrator after upgrading.
    people = self[:people]
    unless people.where(admin: true).count.positive?
      people.order(:id).limit(1).update(admin: true)
    end
  end
end
