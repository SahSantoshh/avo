class Avo::Resources::Store < Avo::BaseResource
  self.includes = [:location]
  self.confirm_on_save = true

  def fields
    field :id, as: :id
    field :name, as: :text
    field :size, as: :text

    if params[:show_location_field] == "1"
      # Example for error message when resource is missing
      field :location, as: :has_one
    end

    if params[:show_items_field] == "1"
      field :items, as: :array
    end

    # Intentionally use the same ID as the :has_many field to test whether the correct association field
    # is retrieved during rendering of the association.
    field :patrons, as: :tags do
      record.patrons.map(&:name)
    end

    field :patrons,
      as: :has_many,
      through: :patronships,
      translation_key: "patrons",
      attach_fields: -> {
        if ENV["TEST_FILL_JOIN_RECORD"]
          field :review, as: :text,
            update_using: -> { ">> #{value} <<" }
        else
          field :review, as: :text
        end
      }
  end
end
