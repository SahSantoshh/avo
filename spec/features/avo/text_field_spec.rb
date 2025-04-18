require "rails_helper"

RSpec.describe "TextField", type: :feature do
  describe "with regular input" do
    let!(:user) { create :user }
    let!(:person) { create :person }

    context "index" do
      it "displays the users first name" do
        visit "/admin/resources/users"

        expect(page).to have_text user.first_name
      end

      it "displays the html for a computed text field" do
        visit "/admin/resources/people"

        expect(page).to have_link person.name, href: "https://avohq.io"
      end
    end

    context "show" do
      it "displays the users first name" do
        visit "/admin/resources/users/#{user.id}"

        expect(page).to have_text user.first_name
      end

      it "displays the html for a computed text field" do
        visit "/admin/resources/people"

        expect(page).to have_link person.name, href: "https://avohq.io"
      end

      it "displays the link to a route from the main app" do
        visit "/admin/resources/users/#{user.id}"

        base_url = Capybara.current_session.current_url.gsub("admin/resources/users/#{user.id}", "")

        expect(page).to have_link "hey", href: "#{base_url}hey"
      end
    end

    context "edit" do
      it "has the users name pre-filled" do
        visit "/admin/resources/users/#{user.id}/edit"

        expect(find_field("user_first_name").value).to eq user.first_name
      end

      it "changes the users name" do
        visit "/admin/resources/users/#{user.id}/edit"

        fill_in "user_first_name", with: "Jack Jack Jack"

        save

        expect(current_path).to eql "/admin/resources/users/#{user.slug}"
        expect(page).to have_text "Jack Jack Jack"
      end
    end
  end

  describe "decorate" do
    let!(:city) { create :city, population: 18000 }

    it "only on display" do
      visit avo.edit_resources_city_path(city)
      expect(find_by_id("city_population").value).to eq("18000")

      visit avo.resources_city_path(city)
      expect(show_field_value(id: :population)).to eq "18.000"

      visit avo.resources_cities_path
      expect(index_field_value(id: :population, record_id: city.to_param)).to eq "18.000"
    end
  end
end
