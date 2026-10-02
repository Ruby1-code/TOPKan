Sequel.migration do
  up do
    # Existing TOPKan installations already have this table. Record this
    # baseline migration without rebuilding the table or touching its rows.
    unless table_exists?(:people)
      create_table(:people) do
        primary_key :id
        String :first_name, null: false
        String :last_name, null: false
        String :email, null: false, unique: true
        String :password, null: false
      end
    end
  end
end
