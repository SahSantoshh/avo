require "rails_helper"

RSpec.feature "belongs_to", type: :system do
  let!(:user) { create :user }
  let!(:post) { create :post }
  let!(:second_post) { create :post, name: "Plums are good" }
  # making more posts so we're certain that we check for the right record
  let!(:other_posts) {
    create_list(:post, 10, body: "zzz") do |post, i|
      post.update(name: "#{Faker::Company.name} - #{i}")
    end
  }
  let!(:project) { create :project }

  let!(:amber) { create :user, first_name: "Amber", last_name: "Johnes" }
  let!(:alicia) { create :user, first_name: "Alicia", last_name: "Johnes" }
  let!(:post) { create :post, name: "Plates are required" }
  let!(:team) { create :team, name: "Apple" }

  before do
    # Update admin so it doesn't come up in the search
    admin.update(first_name: "Jim", last_name: "Johnes")
  end

  describe "not searchable" do
    context "new" do
      context "without an association" do
        context "when filling the poly association" do
          describe "creating a polymorphic association" do
            it "creates the comment" do
              expect(Comment.count).to eq 0
              visit "/admin/resources/comments/new"

              expect(page).to have_select "comment_commentable_type", options: ["Choose an option", "Post", "Project"], selected: "Choose an option"

              fill_in "comment_body", with: "Sample comment"
              select "Post", from: "comment_commentable_type"
              select post.name, from: "comment_commentable_id"
              save

              expect(Comment.count).to eq 1
              comment = Comment.first

              expect(page).to have_current_path "/admin/resources/comments"

              return_to_comment_page

              expect(current_path).to eq "/admin/resources/comments/#{comment.id}"

              expect(find_field_value_element("body")).to have_text "Sample comment"
              expect(page).to have_link post.name, href: "/admin/resources/posts/#{post.slug}?via_record_id=#{Comment.last.to_param}&via_resource_class=Avo%3A%3AResources%3A%3AComment"

              click_on "Edit"

              expect(page).to have_select "comment_commentable_type", options: ["Choose an option", "Post", "Project"], selected: "Post"
              expect(page).to have_select "comment_commentable_id", options: ["Choose an option", post.name, second_post.name, *other_posts.map(&:name)], selected: post.name

              # Switch between types and check that values are kept for each one.
              select "Project", from: "comment_commentable_type"
              expect(page).to have_select "comment_commentable_id", options: ["Choose an option", project.name], selected: "Choose an option"
              select "Post", from: "comment_commentable_type"
              expect(page).to have_select "comment_commentable_id", options: ["Choose an option", post.name, second_post.name, *other_posts.map(&:name)], selected: post.name

              # Switch to Project, select one and save
              select "Project", from: "comment_commentable_type"
              select project.name, from: "comment_commentable_id"
              select "Post", from: "comment_commentable_type"
              select other_posts.last.name, from: "comment_commentable_id"

              save

              expect(Comment.last.commentable_type).to eql "Post"
              expect(Comment.last.commentable_id).to eql other_posts.last.id
            end
          end
        end
      end

      context "with an association" do
        let!(:comment) { create :comment, commentable: project }

        it "shows the associated record" do
          visit "/admin/resources/comments/#{comment.id}/edit"

          expect(page).to have_select "comment_commentable_type", options: ["Choose an option", "Post", "Project"], selected: "Project"
          expect(page).to have_select "comment_commentable_id", options: ["Choose an option", project.name], selected: project.name
        end

        describe "nullifying a polymorphic association" do
          context "with just selecting a different association" do
            let!(:project) { create :project }
            let!(:comment) { create :comment, commentable: project }

            it "empties the commentable association" do
              visit "/admin/resources/comments/#{comment.id}/edit"

              expect(page).to have_select "comment_commentable_type", options: ["Choose an option", "Post", "Project"], selected: "Project"
              expect(page).to have_select "comment_commentable_id", options: ["Choose an option", project.name], selected: project.name

              select "Post", from: "comment_commentable_type"
              save

              return_to_comment_page

              expect(find_field_value_element("commentable")).to have_text empty_dash
            end

            it "changes associated record" do
              visit "/admin/resources/comments/#{comment.id}/edit"

              expect(page).to have_select "comment_commentable_type", options: ["Choose an option", "Post", "Project"], selected: "Project"
              expect(page).to have_select "comment_commentable_id", options: ["Choose an option", project.name], selected: project.name

              select "Post", from: "comment_commentable_type"
              select post.name, from: "comment_commentable_id"
              save

              return_to_comment_page

              expect(find_field_value_element("commentable")).to have_text post.name
            end
          end
        end
      end
    end

    describe "within a parent model" do
      let!(:project) { create :project }
      let!(:comment) { create :comment, body: "hey there", user: user, commentable: project }

      it "has the associated record details prefilled" do
        visit "/admin/resources/comments/new?via_relation=commentable&via_relation_class=Project&via_record_id=#{project.to_param}"

        expect(find("#comment_commentable_type").value).to eq "Project"
        expect(find("#comment_commentable_type").disabled?).to be true
        expect(find("#comment_commentable_id").value).to eq project.id.to_s
        expect(find("#comment_commentable_id").disabled?).to be true
      end

      context "in a project show page" do
        it "has the comment listed" do
          visit "/admin/resources/projects/#{project.id}"

          scroll_to comments_frame = find('turbo-frame[id="has_many_field_show_comments"]')

          expect(comments_frame).not_to have_text "Commentable"
          expect(comments_frame).to have_link comment.id.to_s, href: "/admin/resources/comments/#{comment.id}?via_record_id=#{project.to_param}&via_resource_class=Avo%3A%3AResources%3A%3AProject"

          click_on comment.id.to_s

          expect(find_field_value_element("body")).to have_text "hey there"
          expect(find_field_value_element("user")).to have_link user.name, href: "/admin/resources/compact_users/#{user.slug}?via_record_id=#{comment.to_param}&via_resource_class=Avo%3A%3AResources%3A%3AComment"
          expect(find_field_value_element("commentable")).to have_link project.name, href: "/admin/resources/projects/#{project.id}?via_record_id=#{comment.to_param}&via_resource_class=Avo%3A%3AResources%3A%3AComment"

          click_on "Edit"

          expect(find_field("comment_body").value).to eql "hey there"
          expect(find_field("comment_user_id").value).to eql user.to_param.to_s
          expect(page).to have_select "comment_commentable_type", options: ["Choose an option", "Post", "Project"], selected: "Project", disabled: true
          expect(page).to have_select "comment_commentable_id", options: ["Choose an option", project.name], selected: project.name, disabled: true

          save

          expect(current_path).to eq "/admin/resources/comments/#{comment.id}"

          expect(page).to have_text "Comment was successfully updated."

          comment.reload

          expect(comment.commentable_type).to eq "Project"
          expect(comment.commentable.id).to eq project.id

          click_on "Go back"
          wait_for_loaded

          expect(current_path).to eq "/admin/resources/projects/#{project.id}"
        end
      end
    end
  end
end

def return_to_comment_page
  click_on Comment.first.id.to_s
  wait_for_loaded
end
