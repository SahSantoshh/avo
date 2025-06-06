require_dependency "avo/application_controller"

module Avo
  class BaseController < ApplicationController
    include Avo::Concerns::FiltersSessionHandler
    include Avo::Concerns::SafeCall

    before_action :set_resource_name
    before_action :set_resource
    before_action :set_applied_filters, only: :index
    before_action :set_record, only: [:show, :edit, :destroy, :update, :preview]
    before_action :set_record_to_fill, only: [:new, :edit, :create, :update]
    before_action :detect_fields
    before_action :set_edit_title_and_breadcrumbs, only: [:edit, :update]
    before_action :fill_record, only: [:create, :update]
    # Don't run base authorizations for associations
    before_action :authorize_base_action, except: :preview, if: -> { controller_name != "associations" }
    before_action :set_pagy_locale, only: :index

    def index
      @page_title = @resource.plural_name.humanize

      if @reflection.present? && !turbo_frame_request?
        add_breadcrumb @record.class.to_s.pluralize, resources_path(resource: @parent_resource)
        add_breadcrumb @parent_resource.record_title, resource_path(record: @record, resource: @parent_resource)
      end
      add_breadcrumb @resource.plural_name.humanize

      set_index_params
      set_filters
      set_actions
      set_query

      # Eager load the associations
      if @resource.includes.present?
        @query = @query.includes(*@resource.includes)
      end

      # Eager load attachments
      if @resource.attachments.present?
        @resource.attachments.each do |attachment|
          @query = @query.send(:"with_attached_#{attachment}")
        end
      end

      apply_sorting if @index_params[:sort_by]

      # Apply filters to the current query
      filters_to_be_applied.each do |filter_class, filter_value|
        @query = filter_class.safe_constantize.new(
          arguments: @resource.get_filter_arguments(filter_class)
        ).apply_query request, @query, filter_value
      end

      safe_call :set_and_apply_scopes
      safe_call :apply_dynamic_filters
      apply_pagination

      # Create resources for each record
      # Duplicate the @resource before hydration to avoid @resource keeping last record.
      @resource.hydrate(params: params)
      @resources = @records.map do |record|
        @resource.dup.hydrate(record: record)
      end

      set_component_for __method__
    end

    def show
      @resource.hydrate(
        record: @record,
        view: Avo::ViewInquirer.new(:show),
        user: _current_user,
        params: params
      ).detect_fields

      set_actions

      @page_title = @resource.default_panel_name.to_s

      # If we're accessing this resource via another resource add the parent to the breadcrumbs.
      if params[:via_resource_class].present? && params[:via_record_id].present?
        via_resource = Avo.resource_manager.get_resource(params[:via_resource_class])
        via_record = via_resource.find_record params[:via_record_id], params: params
        via_resource = via_resource.new record: via_record

        add_breadcrumb via_resource.plural_name, resources_path(resource: via_resource)
        add_breadcrumb via_resource.record_title, resource_path(record: via_record, resource: via_resource)

        add_breadcrumb @resource.plural_name.humanize
      else
        add_breadcrumb @resource.plural_name.humanize, resources_path(resource: @resource)
      end


      add_breadcrumb @resource.record_title
      add_breadcrumb I18n.t("avo.details").upcase_first

      set_component_for __method__
    end

    def new
      # Record is already hydrated on set_record_to_fill method
      @record = @resource.record
      @resource.hydrate(view: Avo::ViewInquirer.new(:new), user: _current_user)

      # Handle special cases when creating a new record via a belongs_to relationship
      if params[:via_belongs_to_resource_class].present?
        return render turbo_stream: turbo_stream.append(Avo::MODAL_FRAME_ID, partial: "avo/base/new_via_belongs_to")
      end

      set_actions

      @page_title = @resource.default_panel_name.to_s

      if is_associated_record?
        via_resource = Avo.resource_manager.get_resource_by_model_class(params[:via_relation_class])
        via_record = via_resource.find_record params[:via_record_id], params: params
        via_resource = via_resource.new record: via_record

        add_breadcrumb via_resource.plural_name, resources_path(resource: via_resource)
        add_breadcrumb via_resource.record_title, resource_path(record: via_record, resource: via_resource)

        add_breadcrumb @resource.plural_name.humanize
      else
        add_breadcrumb @resource.plural_name.humanize, resources_path(resource: @resource)
      end

      add_breadcrumb t("avo.new").humanize

      set_component_for __method__, fallback_view: :edit
    end

    def create
      # This means that the record has been created through another parent record and we need to attach it somehow.
      if params[:via_record_id].present? && params[:via_belongs_to_resource_class].nil?
        @reflection = @record.class.reflect_on_association(params[:via_relation])
        # Figure out what kind of association does the record have with the parent record

        # Fills in the required info for belongs_to and has_many
        # Get the foreign key and set it to the id we received in the params
        if @reflection.is_a?(ActiveRecord::Reflection::BelongsToReflection) || @reflection.is_a?(ActiveRecord::Reflection::HasManyReflection)
          related_resource = Avo.resource_manager.get_resource_by_model_class params[:via_relation_class]
          @related_record = related_resource.find_record params[:via_record_id], params: params

          @record.send(:"#{@reflection.foreign_key}=", @related_record.id)
        end

        # For when working with has_one, has_one_through, has_many_through, has_and_belongs_to_many, polymorphic
        if @reflection.is_a?(ActiveRecord::Reflection::ThroughReflection) || @reflection.is_a?(ActiveRecord::Reflection::HasAndBelongsToManyReflection)
          # find the record
          via_resource = Avo.resource_manager.get_resource_by_model_class(params[:via_relation_class])
          @related_record = via_resource.find_record params[:via_record_id], params: params
          association_name = BaseResource.valid_association_name(@record, params[:via_relation])

          if params[:via_association_type] == "has_one"
            # On has_one scenarios we should switch the @record and @related_record
            @related_record.send(:"#{@reflection.parent_reflection.inverse_of.name}=", @record)
          else
            @record.send(association_name) << @related_record
          end
        end
      end

      # record gets instantiated and filled in the fill_record method
      saved = save_record
      @resource.hydrate(record: @record, view: Avo::ViewInquirer.new(:new), user: _current_user)

      add_breadcrumb @resource.plural_name.humanize, resources_path(resource: @resource)
      add_breadcrumb t("avo.new").humanize
      set_actions

      set_component_for :edit

      if saved
        create_success_action
      else
        create_fail_action
      end
    end

    def edit
      set_actions

      set_component_for __method__
    end

    def update
      # record gets instantiated and filled in the fill_record method
      saved = save_record
      @resource = @resource.hydrate(record: @record, view: Avo::ViewInquirer.new(:edit), user: _current_user)
      set_actions

      set_component_for :edit

      if saved
        update_success_action
      else
        update_fail_action
      end
    end

    def destroy
      if destroy_model
        destroy_success_action
      else
        destroy_fail_action
      end
    end

    def preview
      @authorized = @authorization.set_record(@record || @resource.model_class).authorize_action :preview, raise_exception: false

      if @authorized
        @resource.hydrate(record: @record, view: Avo::ViewInquirer.new(:show), user: _current_user, params: params)

        @preview_fields = @resource.get_preview_fields
      end

      render layout: params[:turbo_frame].blank?
    end

    private

    def save_record
      perform_action_and_record_errors do
        save_record_action
      end
    end

    def save_record_action
      @record.save!
    end

    def destroy_model
      perform_action_and_record_errors do
        destroy_record_action
      end
    end

    def destroy_record_action
      @record.destroy!
    end

    def perform_action_and_record_errors(&block)
      begin
        succeeded = block.call
      rescue ActiveRecord::RecordInvalid => error
        log_error error

        # Do nothing as the record errors are already being displayed
        # On associations controller add errors from join record to record
        if controller_name == "associations"
          @record.errors.add(:base, error.message)
        end
      rescue => exception
        log_error exception

        # In case there's an error somewhere else than the record
        # Example: When you save a license that should create a user for it and creating that user throws and error.
        # Example: When you Try to delete a record and has a foreign key constraint.
        @record.errors.add(:base, exception.message)
        @backtrace = exception.backtrace
      end

      # This method only needs to return true or false to indicate if the action was successful
      @record.errors.any? ? false : succeeded
    end

    def log_error(error)
      return if Rails.env.production?

      Rails.logger.error error
      Rails.logger.error error.backtrace.join("\n")
    end

    def model_params
      request_params = params.require(model_param_key).permit(permitted_params)

      if @resource.devise_password_optional && request_params[:password].blank? && request_params[:password_confirmation].blank?
        request_params.delete(:password_confirmation)
        request_params.delete(:password)
      end

      request_params
    end

    def permitted_params
      @resource.get_field_definitions
        .select(&:updatable)
        .map(&:to_permitted_param)
        .concat(extra_params)
        .push(@resource.safe_call(:nested_params))
        .uniq
    end

    def extra_params
      @resource.class.extra_params || []
    end

    def cast_nullable(params)
      fields = @resource.get_field_definitions

      nullable_fields = fields
        .filter do |field|
          field.nullable
        end
        .map do |field|
          [field.id, field.null_values]
        end
        .to_h

      params.each do |key, value|
        nullable_values = nullable_fields[key.to_sym]

        if nullable_values.present? && value.in?(nullable_values)
          params[key] = nil
        end
      end

      params
    end

    def set_index_params
      @index_params = {}

      set_pagination_params

      # Sorting
      @index_params[:sort_by] = params[:sort_by] || @resource.sort_by_param

      @index_params[:sort_direction] = params[:sort_direction] || @resource.default_sort_direction

      if @resource.available_view_types.exclude? @resource.view_type.to_sym
        raise "View type '#{@resource.view_type}' is unavailable for #{@resource.class}."
      end
    end

    def set_filters
      @filters = @resource
        .get_filters
        .map do |filter|
          filter[:class].new arguments: filter[:arguments]
        end
        .select do |filter|
          filter.visible_in_view(resource: @resource, parent_resource: @parent_resource)
        end
    end

    def set_actions
      @actions = @resource
        .get_actions
        .map do |action_bag|
          action_bag.delete(:class).new(record: @record, resource: @resource, view: @view, **action_bag)
        end
        .select do |action|
          action.is_a?(DividerComponent) || action.visible_in_view(parent_resource: @parent_resource)
        end
    end

    def set_applied_filters
      reset_filters if params[:reset_filter]

      # Return if there are no filters or if the filters are actually ActionController::Parameters (used by dynamic filters)
      return @applied_filters = {} if (fetched_filters = fetch_filters).blank? || fetched_filters.is_a?(ActionController::Parameters)

      @applied_filters = Avo::Filters::BaseFilter.decode_filters(fetched_filters)

      # Some filters react to others and will have to be merged into this
      @applied_filters = @applied_filters.merge reactive_filters
    end

    def reactive_filters
      filter_reactions = {}

      # Go through all filters
      @resource.get_filters
        .select do |filter|
          filter[:class].instance_methods(false).include? :react
        end
        .each do |filter|
          # Run the react method if it's present
          reaction = filter[:class].new(arguments: filter[:arguments]).react

          next if reaction.nil?

          filter_reactions[filter[:class].to_s] = reaction
        end

      filter_reactions
    end

    # Get the default state of the filters and override with the user applied filters
    def filters_to_be_applied
      filter_defaults = {}

      @resource.get_filters.each do |filter|
        filter = filter[:class].new arguments: filter[:arguments]

        unless filter.default.nil?
          filter_defaults[filter.class.to_s] = filter.default
        end
      end

      filter_defaults.merge(@applied_filters)
    end

    def set_edit_title_and_breadcrumbs
      @resource = @resource.hydrate(record: @record, view: Avo::ViewInquirer.new(:edit), user: _current_user)
      @page_title = @resource.default_panel_name.to_s

      last_crumb_args = {}
      # If we're accessing this resource via another resource add the parent to the breadcrumbs.
      if params[:via_resource_class].present? && params[:via_record_id].present?
        via_resource = Avo.resource_manager.get_resource(params[:via_resource_class])
        via_record = via_resource.find_record params[:via_record_id], params: params
        via_resource = via_resource.new record: via_record

        add_breadcrumb via_resource.plural_name, resources_path(resource: @resource)
        add_breadcrumb via_resource.record_title, resource_path(record: via_record, resource: via_resource)

        last_crumb_args = {
          via_resource_class: params[:via_resource_class],
          via_record_id: params[:via_record_id]
        }
        add_breadcrumb @resource.plural_name.humanize
      else
        add_breadcrumb @resource.plural_name.humanize, resources_path(resource: @resource)
      end

      add_breadcrumb @resource.record_title, resource_path(record: @resource.record, resource: @resource, **last_crumb_args)
      add_breadcrumb t("avo.edit").humanize
    end

    def create_success_action
      return render "close_modal_and_reload_field" if params[:via_belongs_to_resource_class].present?

      respond_to do |format|
        format.html { redirect_to after_create_path, notice: create_success_message }
      end
    end

    def create_fail_action
      flash.now[:error] = create_fail_message

      respond_to do |format|
        format.html { render :new, status: :unprocessable_entity }
        format.turbo_stream { render "create_fail_action" }
      end
    end

    def create_success_message
      "#{@resource.name} #{t("avo.was_successfully_created")}."
    end

    def create_fail_message
      t "avo.you_missed_something_check_form"
    end

    def after_create_path
      # If this is an associated record return to the association show page
      if is_associated_record?
        parent_resource = if params[:via_resource_class].present?
          Avo.resource_manager.get_resource(params[:via_resource_class])
        else
          Avo.resource_manager.get_resource_by_model_class(params[:via_relation_class])
        end

        return resource_view_path(resource: parent_resource, resource_id: params[:via_record_id])
      end

      redirect_path_from_resource_option(:after_create_path) || resource_view_response_path
    end

    def update_success_action
      respond_to do |format|
        format.html { redirect_to after_update_path, notice: update_success_message }
      end
    end

    def update_fail_action
      flash.now[:error] = update_fail_message

      respond_to do |format|
        format.html { render :edit, status: :unprocessable_entity }
        format.turbo_stream { render "update_fail_action" }
      end
    end

    def update_success_message
      "#{@resource.name} #{t("avo.was_successfully_updated")}."
    end

    def update_fail_message
      t "avo.you_missed_something_check_form"
    end

    def after_update_path
      # The `return_to` param takes precedence over anything else.
      return params[:return_to] if params[:return_to].present?
      return params[:referrer] if params[:referrer].present?

      redirect_path_from_resource_option(:after_update_path) || resource_view_response_path
    end

    # Requires a different/special name, otherwise, in some places, this can be called instead helpers.resource_view_path
    def resource_view_response_path
      helpers.resource_view_path(record: @record, resource: @resource)
    end

    def destroy_success_action
      flash[:notice] = destroy_success_message

      respond_to do |format|
        if params[:turbo_frame]
          format.turbo_stream do
            render turbo_stream: reload_frame_turbo_streams
          end
        else
          format.html { redirect_to after_destroy_path }
        end
      end
    end

    def destroy_fail_action
      flash[:error] = destroy_fail_message

      respond_to do |format|
        format.turbo_stream { render turbo_stream: turbo_stream.avo_flash_alerts }
      end
    end

    def destroy_success_message
      t("avo.resource_destroyed", attachment_class: @attachment_class)
    end

    def destroy_fail_message
      errors = @record.errors.full_messages
      errors.present? ? errors.join(". ") : t("avo.failed")
    end

    def after_destroy_path
      params[:referrer] || resources_path(resource: @resource, turbo_frame: params[:turbo_frame], view_type: params[:view_type])
    end

    def redirect_path_from_resource_option(action = :after_update_path)
      return nil if @resource.class.send(action).blank?

      extra_args = {}
      extra_args[:return_to] = params[:return_to] if params[:return_to].present?

      if @resource.class.send(action) == :index
        resources_path(resource: @resource, **extra_args)
      elsif @resource.class.send(action) == :edit || Avo.configuration.resource_default_view.edit?
        edit_resource_path(resource: @resource, record: @resource.record, **extra_args)
      else
        resource_path(record: @record, resource: @resource, **extra_args)
      end
    end

    def is_associated_record?
      params[:via_relation_class].present? && params[:via_record_id].present?
    end

    # Set pagy locale from params or from avo configuration, if both nil locale = "en"
    def set_pagy_locale
      @pagy_locale = locale.to_s || Avo.configuration.default_locale || "en"
    end

    def pagy_query
      @query
    end

    # Set the view component for the current view
    # It will try to use the custom component if it's set, otherwise it will use the default one
    def set_component_for(view, fallback_view: nil)
      default_component = "Avo::Views::Resource#{(fallback_view || view).to_s.classify}Component"

      # Search for the custom component by key and by class name:
      custom_component = @resource.custom_components.dig(:"resource_#{view}_component") ||
        @resource.custom_components.dig(default_component)

      # If the component is not set, use the default one
      return @component = default_component.constantize if custom_component.nil?

      # If the component is set, try to use it
      @component = custom_component.to_s.safe_constantize

      # If the component is not found, raise an error
      if @component.nil?
        raise "The component '#{custom_component}' was not found.\n" \
        "That component was fetched from 'self.components' option inside '#{@resource.class}' resource."
      end
    end

    def apply_pagination
      # Set `trim_extra` to false in associations so the first page has the `page=1` param assigned
      @pagy, @records = @resource.apply_pagination(index_params: @index_params, query: pagy_query, trim_extra: @related_resource.blank?)
    end

    def apply_sorting
      sort_by = @index_params[:sort_by].to_sym
      if sort_by != :created_at
        @query = @query.unscope(:order)
      end

      # Verify that sort_by param actually is bonded to a field.
      field = @resource.get_field(sort_by)

      # Check if the sortable field option is a proc and if there is a need to do a custom sort
      @query = if field.present? && field.sortable.is_a?(Proc)
        Avo::ExecutionContext.new(target: field.sortable, query: @query, direction: sanitized_sort_direction).handle
      # Sanitize sort_by param by checking if have bounded field.
      elsif (field.present? || sort_by == :created_at) && sanitized_sort_direction
        @query.order("#{@resource.model_class.table_name}.#{sort_by} #{sanitized_sort_direction}")
      # Transform Model to ActiveRecord::Relation because Avo expects one.
      else
        @query.where("1=1")
      end
    end

    # Sanitize sort_direction param
    def sanitized_sort_direction
      @sanitized_sort_direction ||= @index_params[:sort_direction].presence_in(["asc", :asc, "desc", :desc])
    end

    def reload_frame_turbo_streams
      [
        turbo_stream.turbo_frame_reload(params[:turbo_frame]),
        turbo_stream.avo_flash_alerts
      ]
    end

    def set_pagination_params
      @index_params[:page] = params[:page] || 1

      # If the request includes the 'per_page' parameter, save its value to the cookies
      cookies[:per_page] = params[:per_page] if params[:per_page].present?

      @index_params[:per_page] = cookies[:per_page] || Avo.configuration.per_page
    end

    # If we don't get a query object predefined from a child controller like associations, just spin one up
    def set_query
      @query ||= @resource.class.query_scope
    end
  end
end
