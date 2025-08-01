class Avo::Resources::Items::Holder
  attr_reader :tools, :from, :parent
  attr_accessor :items
  attr_accessor :invalid_fields

  def initialize(from: nil, parent: nil)
    @items = []
    @items_index = 0
    @invalid_fields = []
    @from = from
    @parent = parent
  end

  def collaboration_timeline(**args)
    add_item Avo::Resources::Items::Collaboration.new(**args)
  end

  # Adds a field to the items_holder
  def field(field_name, **args, &block)
    # If the field is paresed inside a tab group, add it to the tab
    # This will happen when the field is parsed inside a tab group from a resource method
    if from.present? && from.class == Avo::Resources::Items::TabGroup::Builder
      return from.field(field_name, holder: self, **args, &block)
    end

    field_parser = Avo::Dsl::FieldParser.new(id: field_name, order_index: @items_index, **args, &block).parse

    if field_parser.invalid?
      as = args.fetch(:as, nil)

      alert_type = :error
      message = "There's an invalid field configuration for this resource. <br/> <code class='px-1 py-px rounded bg-red-600'>field :#{field_name}, as: :#{as}</code>"

      if as == :markdown
        alert_type = :warning
        message = "In Avo 3.16.2 we renamed the <code>:markdown</code> field to <code>:easy_mde</code>. <br/><br/>You may continue to use that one or the new and improved one with Active Storage support. <br/><br/> Read more about it in the <a href=\"https://docs.avohq.io/3.0/fields/markdown.html\" target=\"_blank\">docs</a>."
      end

      # End execution ehre and add the field to the invalid_fileds payload so we know to wanr the developer about that.
      # @todo: Make sure this warning is still active
      return add_invalid_field({
        name: field_name,
        as:,
        alert_type:,
        message:
      })
    end

    add_item field_parser.instance
  end

  def tabs(tab = nil, id: nil, name: nil, title: nil, description: nil, **args, &block)
    if tab.present?
      add_item tab
    else
      add_item Avo::Resources::Items::TabGroup::Builder.parse_block(
        parent: @parent,
        id: id,
        name: name,
        title: title,
        description: description,
        **args,
        &block
      )
    end
  end

  def tab(name, **args, &block)
    add_item Avo::Resources::Items::Tab::Builder.parse_block(name: name, parent: @parent, **args, &block)
  end

  def cluster(**args, &block)
    add_item Avo::Resources::Items::Row::Builder.parse_block(parent: @parent, **args, &block)
  end

  # def row
  alias_method :row, :cluster

  def tool(klass, **args)
    add_item klass.new(**args, view: self.parent.view, parent: self.parent)
  end

  def panel(panel_name = nil, **args, &block)
    add_item Avo::Resources::Items::ItemGroup::Builder.parse_block(name: panel_name, parent: @parent, **args, &block)
  end

  # The main panel is the one that also render the header of the resource with the breadcrumbs, the title and the controls.
  def main_panel(**args, &block)
    add_item Avo::Resources::Items::MainPanel::Builder.parse_block(name: "main_panel", parent: @parent, **args, &block)
  end

  def sidebar(**args, &block)
    check_sidebar_is_inside_a_panel

    add_item Avo::Resources::Items::Sidebar::Builder.parse_block(parent: @parent, **args, &block)
  end

  def add_item(instance)
    @items << instance

    increment_order_index
  end

  private

  def add_invalid_field(payload, alert_type: :error)
    invalid_fields << payload
  end

  def increment_order_index
    @items_index += 1
  end

  def check_sidebar_is_inside_a_panel
    unless @from.eql?(Avo::Resources::Items::Panel::Builder) || @from.eql?(Avo::Resources::Items::MainPanel::Builder)
      raise "The sidebar must be inside a panel."
    end
  end
end
