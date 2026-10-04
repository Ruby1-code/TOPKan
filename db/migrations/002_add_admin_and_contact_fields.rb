Sequel.migration do
  up do
    # Some databases may already have some or all of these fields (for example,
    # if they were added in a DB manager before the migration was recorded).
    existing_columns = schema(:people).map(&:first)
    columns_to_add = {
      admin: { type: TrueClass, null: false, default: false },
      telephone1: { type: String, size: 20 },
      sNumber: { type: Integer },
      sName: { type: String, size: 50 },
      comments: { type: String, size: 500 }
    }

    columns_to_add.each do |column, options|
      next if existing_columns.include?(column)

      alter_table(:people) do
        add_column column, options.fetch(:type), **options.reject { |key, _| key == :type }
      end
    end

    # Keep the existing login usable as an administrator after upgrading.
    people = self[:people]
    unless people.where(admin: true).count.positive?
      first_person = people.order(:id).first
      people.where(id: first_person[:id]).update(admin: true) if first_person
    end
  end
end
