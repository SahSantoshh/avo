require_dependency "avo/base_controller"

module Avo
  class AssociationsController < BaseController
    before_action :set_record, only: [:show, :index, :new, :create, :destroy]
    before_action :set_related_resource_name
    before_action :set_related_resource, only: [:show, :index, :new, :create, :destroy]
    before_action :set_related_authorization
    before_action :set_reflection_field
    before_action :set_related_record, only: [:show]
    before_action :set_reflection
    before_action :set_attachment_class, only: [:show, :index, :new, :create, :destroy]
    before_action :set_attachment_resource, only: [:show, :index, :new, :create, :destroy]
    before_action :set_attachment_record, only: [:create, :destroy]
    before_action :set_attach_fields, only: [:new, :create]
    before_action :authorize_index_action, only: :index
    before_action :authorize_attach_action, only: :new
    before_action :authorize_detach_action, only: :destroy

    layout :choose_layout

    def index
      @parent_resource = @resource.dup
      @resource = @related_resource
      @parent_record = @parent_resource.find_record(params[:id], params: params)
      @parent_resource.hydrate(record: @parent_record)

      # When array field the records are fetched from the field block, from the parent record or from the resource def records
      # When other field type, like has_many the @query is directly fetched from the parent record
      # Don't apply policy on array type since it can return an array of hashes where `.all` and other methods used on policy will fail.
      @query = if @field.type == "array"
        @resource.fetch_records(Avo::ExecutionContext.new(target: @field.block, record: @parent_record).handle || @parent_record.try(@field.id))
      else
        @related_authorization.apply_policy(
          @parent_record.send(
            BaseResource.valid_association_name(@parent_record, association_from_params)
          )
        )
      end

      @association_field = find_association_field(resource: @parent_resource, association: params[:related_name])

      if @association_field.present? && @association_field.scope.present?
        @query = Avo::ExecutionContext.new(
          target: @association_field.scope,
          query: @query,
          parent: @parent_record,
          resource: @resource,
          parent_resource: @parent_resource
        ).handle
      end

      super
    end

    def show
      @parent_resource, @parent_record = @resource, @record

      @resource, @record = @related_resource, @related_record

      super
    end

    def new
      @resource.hydrate(record: @record)

      if @field.present? && !@field.is_searchable?
        query = @related_authorization.apply_policy @attachment_class

        # Add the association scope to the query scope
        if @field.attach_scope.present?
          query = Avo::ExecutionContext.new(target: @field.attach_scope, query: query, parent: @record).handle
        end

        @options = select_options(query)
      end

      @url = Avo::Services::URIService.parse(avo.root_url.to_s)
        .append_paths("resources", params[:resource_name], params[:id], params[:related_name])
        .append_query(
          {
            view: @resource&.view&.to_s,
            for_attribute: @field&.try(:for_attribute)
          }.compact
        )
        .to_s
    end

    def create
      if create_association
        create_success_action
      else
        create_fail_action
      end
    end

    def create_association
      association_name = BaseResource.valid_association_name(@record, association_from_params)

      perform_action_and_record_errors do
        if through_reflection? && additional_params.present?
          new_join_record.save
        elsif has_many_reflection? || through_reflection?
          @record.send(association_name) << @attachment_record
        else
          @record.send(:"#{association_name}=", @attachment_record)
          @record.save!
        end
      end
    end

    def destroy
      association_name = BaseResource.valid_association_name(@record, @field.for_attribute || params[:related_name])

      if through_reflection?
        join_record.destroy!
      elsif has_many_reflection?
        @record.send(association_name).delete @attachment_record
      else
        @record.send(:"#{association_name}=", nil)
      end

      destroy_success_action
    end

    private

    def set_reflection
      @reflection = @record.class.try(:reflect_on_association, association_from_params)

      return if @reflection.blank? && @field.type == "array"

      # Ensure inverse_of is present on STI
      if !@record.class.descends_from_active_record? && @reflection.inverse_of.blank? && Rails.env.development?
        raise "Avo relies on the 'inverse_of' option to establish the inverse association and perform some specific logic.\n" \
          "Please configure the 'inverse_of' option for the '#{@reflection.macro} :#{@reflection.name}' association " \
          "in the '#{@reflection.active_record.name}' model."
      end
    end

    def set_attachment_class
      # @reflection is nil whe using an Array field.
      @attachment_class = @reflection&.klass
    end

    def set_attachment_resource
      @attachment_resource = @field.use_resource || (Avo.resource_manager.get_resource_by_model_class @attachment_class)
    end

    def set_attachment_record
      @attachment_record = @related_resource.find_record attachment_id, params: params
    end

    def set_reflection_field
      @field = find_association_field(resource: @resource, association: @related_resource_name)
      @field.hydrate(resource: @resource, record: @record, view: Avo::ViewInquirer.new(:new))
    rescue
    end

    def attachment_id
      params[:related_id] || params.dig(:fields, :related_id)
    end

    def reflection_class
      if @reflection.is_a?(ActiveRecord::Reflection::ThroughReflection)
        @reflection.through_reflection.class
      else
        @reflection.class
      end
    end

    def authorize_if_defined(method, record = @record)
      return unless Avo.configuration.authorization_enabled?

      @authorization.set_record(record)

      if @authorization.has_method?(method.to_sym)
        @authorization.authorize_action method.to_sym
      elsif Avo.configuration.explicit_authorization
        raise Avo::NotAuthorizedError.new
      end
    end

    def authorize_index_action
      authorize_if_defined "view_#{@field.id}?"
    end

    def authorize_attach_action
      authorize_if_defined "attach_#{@field.id}?"
    end

    def authorize_detach_action
      authorize_if_defined "detach_#{@field.id}?", @attachment_record
    end

    def set_related_authorization
      @related_authorization = if @related_resource.present?
        @related_resource.authorization(user: _current_user)
      else
        Services::AuthorizationService.new _current_user
      end
    end

    def association_from_params
      @field&.for_attribute || params[:related_name]
    end

    def source_foreign_key
      @reflection.source_reflection.foreign_key
    end

    def through_foreign_key
      @reflection.through_reflection.foreign_key
    end

    def join_record
      @reflection.through_reflection.klass.find_by(source_foreign_key => @attachment_record.id,
        through_foreign_key => @record.id)
    end

    def has_many_reflection?
      reflection_class.in? [
        ActiveRecord::Reflection::HasManyReflection,
        ActiveRecord::Reflection::HasAndBelongsToManyReflection
      ]
    end

    def through_reflection?
      @reflection.instance_of? ActiveRecord::Reflection::ThroughReflection
    end

    def additional_params
      @additional_params ||= params[:fields].slice(*@attach_fields&.map(&:id))
    end

    def set_attach_fields
      @attach_fields = if @field.attach_fields.present?
        Avo::FieldsExecutionContext.new(target: @field.attach_fields)
          .detect_fields
          .items_holder
          .items
      end
    end

    def new_join_record
      @resource.fill_record(
        @reflection.through_reflection.klass.new(
          source_foreign_key => @attachment_record.id,
          through_foreign_key => @record.id
        ),
        additional_params,
        fields: @attach_fields,
      )
    end

    def create_success_action
      flash[:notice] = t("avo.attachment_class_attached", attachment_class: @related_resource.name)

      respond_to do |format|
        if params[:turbo_frame].present?
          format.turbo_stream { render turbo_stream: reload_frame_turbo_streams }
        else
          format.html { redirect_back fallback_location: resource_view_response_path }
        end
      end
    end

    def reload_frame_turbo_streams
      turbo_streams = super

      # We want to close the modal if the user wants to add just one record
      turbo_streams << turbo_stream.avo_close_modal if params[:button] != "attach_another"

      turbo_streams
    end

    def create_fail_action
      flash[:error] = t("avo.attachment_failed", attachment_class: @related_resource.name)

      respond_to do |format|
        format.turbo_stream {
          render turbo_stream: turbo_stream.append("alerts", partial: "avo/partials/all_alerts")
        }
      end
    end

    def destroy_success_action
      flash[:notice] = t("avo.attachment_class_detached", attachment_class: @attachment_class)

      respond_to do |format|
        if params[:turbo_frame].present?
          format.turbo_stream do
            render turbo_stream: reload_frame_turbo_streams
          end
        else
          format.html { redirect_to params[:referrer] || resource_view_response_path }
        end
      end
    end

    def select_options(query)
      query.all.limit(Avo.configuration.associations_lookup_list_limit).map do |record|
        [@attachment_resource.new(record: record).record_title, record.to_param]
      end.tap do |options|
        options << t("avo.more_records_available") if options.size == Avo.configuration.associations_lookup_list_limit
      end
    end

    def pagination_key
      @pagination_key ||= "#{@parent_resource.class.to_s.parameterize}.has_many.#{@related_resource.class.to_s.parameterize}"
    end

    def set_pagination_params
      set_page_param
      set_per_page_param
    end

    def set_page_param
      # avo-resources-project.has_many.avo-resources-user.page
      page_key = "#{pagination_key}.page"

      @index_params[:page] = if Avo.configuration.session_persistence_enabled?
        session[page_key] = params[:page] || session[page_key] || 1
      else
        params[:page] || 1
      end
    end

    def set_per_page_param
      # avo-resources-project.has_many.avo-resources-user.per_page
      per_page_key = "#{pagination_key}.per_page"

      @index_params[:per_page] = if Avo.configuration.session_persistence_enabled?
        session[per_page_key] = params[:per_page] || session[per_page_key] || Avo.configuration.via_per_page
      else
        params[:per_page] || Avo.configuration.via_per_page
      end
    end
  end
end
