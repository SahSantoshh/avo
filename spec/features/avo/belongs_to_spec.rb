require "rails_helper"

RSpec.feature "belongs_to", type: :feature do
  context "index" do
    describe "with a related user" do
      let!(:post) { create :post, user: admin }
    end
  end

  context "index" do
    let(:url) { "/admin/resources/posts?view_type=table" }

    subject do
      visit url
      find("[data-resource-id='#{post.to_param}'] [data-field-id='user']")
    end

    describe "with a related user" do
      let!(:post) { create :post, user: admin }

      it { is_expected.to have_text admin.name }
      it { is_expected.to have_link admin.name, href: "/admin/resources/users/#{admin.slug}" }
    end

    describe "with a related user with link to record enabled" do
      let!(:user) { create :user, first_name: "Alicia" }
      let!(:comment) { create :comment, body: "a comment", user: user }

      subject do
        visit "/admin/resources/comments"
        find("[data-resource-id='#{comment.to_param}'] [data-field-id='user']")
      end

      it { is_expected.to have_link user.name, href: "/admin/resources/comments/#{comment.id}" }
    end

    describe "without a related user" do
      let!(:post) { create :post }

      it { is_expected.to have_text empty_dash }
    end
  end

  subject do
    visit url
    find_field_value_element("user")
  end

  context "show" do
    let(:url) { "/admin/resources/posts/#{post.slug}" }

    describe "with user attached" do
      let!(:post) { create :post, user: admin }

      it { is_expected.to have_link admin.name, href: "/admin/resources/users/#{admin.slug}?via_record_id=#{post.slug}&via_resource_class=Avo%3A%3AResources%3A%3APost" }
    end

    describe "without user attached" do
      let!(:post) { create :post }

      it { is_expected.to have_text empty_dash }
    end
  end

  context "edit" do
    let(:url) { "/admin/resources/posts/#{post.id}/edit" }

    describe "without user attached" do
      let!(:post) { create :post, user: nil }

      it { is_expected.to have_select "post_user_id", selected: nil, options: [empty_dash, admin.name] }

      it "changes the user" do
        visit url
        expect(page).to have_select "post_user_id", selected: nil, options: [empty_dash, admin.name]

        select admin.name, from: "post_user_id"

        save

        expect(current_path).to eql "/admin/resources/posts/#{post.slug}"
        expect(page).to have_link admin.name, href: "/admin/resources/users/#{admin.slug}?via_record_id=#{post.slug}&via_resource_class=Avo%3A%3AResources%3A%3APost"
      end
    end

    describe "with user attached" do
      let!(:post) { create :post, user: admin }
      let!(:second_user) { create :user }

      it { is_expected.to have_select "post_user_id", selected: admin.name }

      it "changes the user" do
        visit url
        expect(page).to have_select "post_user_id", selected: admin.name

        select second_user.name, from: "post_user_id"

        save

        expect(current_path).to eql "/admin/resources/posts/#{post.slug}"
        expect(page).to have_link second_user.name, href: "/admin/resources/users/#{second_user.slug}?via_record_id=#{post.slug}&via_resource_class=Avo%3A%3AResources%3A%3APost"
      end

      it "nullifies the user" do
        visit url
        expect(page).to have_select "post_user_id", selected: admin.name

        select empty_dash, from: "post_user_id"

        save

        expect(current_path).to eql "/admin/resources/posts/#{post.slug}"
        expect(find_field_value_element("user")).to have_text empty_dash
      end
    end
  end

  context "new" do
    let(:url) { "/admin/resources/posts/new?via_relation=user&via_record_id=#{admin.to_param}&via_relation_class=User" }

    it { is_expected.to have_select "post_user_id", selected: admin.name, options: [empty_dash, admin.name], disabled: true }

    describe "with belongs_to foreign key field disabled" do
      let!(:course) { create :course }

      it "saves the related comment" do
        expect(Course::Link.count).to be 0

        visit "/admin/resources/course_links/new?via_relation=course&via_record_id=#{course.to_param}&via_relation_class=Course"

        fill_in "course_link_link", with: "https://avo.cool"

        save

        # When the validation fails for any reason, the user is redirected to this weird `/new` path with the newly created model populating the form
        # This test is valid only as a system test. The feature test does not cover this edge-case
        expect(current_path).not_to eq "/admin/resources/course_links/new"
        expect(Course::Link.count).to be 1
        expect(Course::Link.first.course_id).to eq course.id
      end
    end
  end

  describe "hidden columns if current association" do
    let!(:user) { create :user, first_name: "Alicia" }
    let!(:comment) { create :comment, body: "a comment", user: user }

    it "hides the User column" do
      visit "/admin/resources/users/#{user.id}/comments?turbo_frame=has_many_field_show_comments"

      expect(find("thead")).to have_text "Id"
      expect(find("thead")).to have_text "Tiny name"
      expect(find("thead")).to have_text "Commentable"
      expect(find("thead")).not_to have_text "User"
      expect(page).to have_text comment.id
      expect(page).to have_text "a comment"
      # breadcrumb contains the user's name
      expect(page).to have_text user.name, count: 1
    end
  end

  describe "with custom primary key set" do
    let!(:event) { create(:event, name: "Sample Event") }

    it "find event by uuid" do
      visit avo.new_resources_volunteer_path

      select event.name, from: "volunteer[event_id]"

      click_on "Save"

      expect(Volunteer.last).to have_attributes(event_id: event.uuid)
    end
  end

  describe "hidden columns if current polymorphic association" do
    let!(:user) { create :user }
    let!(:project) { create :project, name: "Haha project" }
    let!(:comment) { create :comment, body: "a comment", user: user, commentable: project }

    it "hides the Commentable column" do
      visit "/admin/resources/projects/#{project.id}/comments?turbo_frame=has_many_field_show_comments"

      expect(find("thead")).to have_text "Id"
      expect(find("thead")).to have_text "Tiny name"
      expect(find("thead")).to have_text "User"
      expect(find("thead")).not_to have_text "Commentable"
      expect(page).to have_text comment.id
      expect(page).to have_text "a comment"
      expect(page).to have_text user.name
      # breadcrumb contains the project's name
      expect(page).to have_text project.name, count: 1
    end
  end

  describe "hidden columns if current polymorphic association" do
    let!(:user) { create :user }
    let!(:team) { create :team, name: "Haha team" }
    let!(:review) { create :review, body: "a review", user: user, reviewable: team }

    it "hides the Reviewable column" do
      visit "/admin/resources/teams/#{team.id}/reviews?turbo_frame=has_many_field_show_reviews"

      expect(find("thead")).to have_text "Id"
      expect(find("thead")).to have_text "Excerpt"
      expect(find("thead")).to have_text "User"
      expect(find("thead")).not_to have_text "Reviewable"
      expect(page).to have_text review.id
      expect(page).to have_text "a review"
      expect(page).to have_text user.name
      # breadcrumb contains the team's name
      expect(page).to have_text team.name, count: 1
    end
  end
end
