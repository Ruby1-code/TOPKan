Sequel.migration do
  up do
    create_table(:passkeys) do
      primary_key :id
      foreign_key :person_id, :people, null: false, on_delete: :cascade
      String :credential_id, text: true, null: false, unique: true
      String :public_key, text: true, null: false
      Integer :sign_count, null: false, default: 0
      String :label, null: false
    end
  end

  down do
    drop_table(:passkeys)
  end
end
