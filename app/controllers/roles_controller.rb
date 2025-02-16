# frozen_string_literal: true

#  Copyright (c) 2012-2017, Jungwacht Blauring Schweiz. This file is part of
#  hitobito and licensed under the Affero General Public License version 3
#  or later. See the COPYING file at the top-level directory or at
#  https://github.com/hitobito/hitobito.

class RolesController < CrudController # rubocop:disable Metrics/ClassLength
  include PrivacyPolicyAcceptable

  respond_to :js

  self.nesting = Group

  decorates :role, :group

  # load group before authorization
  prepend_before_action :parent

  skip_authorize_resource only: [:details, :role_types]

  define_render_callbacks :create

  before_render_form :set_group_selection
  before_render_create :set_group_selection

  before_action :set_person_id, only: [:new] # rubocop:disable Rails/LexicallyScopedActionFilter
  before_action :remember_primary_group, only: [:destroy, :update]
  after_action :last_primary_group_role_deleted, only: [:destroy, :update]

  def create
    assign_attributes
    with_person_add_request do
      new_person = entry.person.new_record?
      created = create_entry_and_person
      add_privacy_policy_not_accepted_error if new_person
      respond_with(entry, success: created, location: after_create_location(new_person))
    end
  end

  def update
    @group = find_group
    if change_type?
      change_type
    else
      assign_attributes
      return destroy_from_update if entry.delete_on&.past?

      super(location: after_update_location)
    end
  end

  def destroy
    super do |format|
      location = can?(:show, entry.person) ? person_path(entry.person_id) : group_path(parent)
      format.html { redirect_to(location) }
    end
  end

  def details
    authorize!(:details, Role)
    @group = find_group
    if model_params && model_params[:type].present?
      @type = @group.class.find_role_type!(model_params[:type])
    end
  end

  def role_types
    authorize!(:role_types, Role)
    @group = Group.find(params.fetch(:role, {})[:group_id])
    @type ||= @group.default_role # rubocop:disable Naming/MemoizedInstanceVariableName
  end

  private

  def destroy_from_update
    destroyed = run_callbacks(:destroy) { entry.destroy }
    if destroyed
      redirect_to(after_update_location, notice: flash_message(:success, :destroy))
    else
      flash.now[:alert] = error_messages.presence || flash_message(:failure, :destroy)
      render :edit
    end
  end

  def with_person_add_request(&block)
    creator = Person::AddRequest::Creator::Group.new(entry, current_ability)
    msg = creator.handle(&block)
    redirect_to group_people_path(entry.group_id), alert: msg if msg
  end

  def create_entry_and_person
    created = false
    Role.transaction do
      created = with_callbacks(:create, :save) do
        (entry.person.persisted? || (privacy_policy_accepted? && entry.person.save)) && entry.save
      end
      raise ActiveRecord::Rollback unless created
    end
    created
  end

  def change_type?
    extract_model_attr(:person_id)
    type = model_params && model_params[:type]

    @group.id != entry.group_id || (type && type != entry.type)
  end

  def change_type
    if create_new_role_and_destroy_old_role
      change_type_successfull
    else
      copy_errors(@new_role)
      render :edit
    end
  end

  def change_type_successfull
    @old_role = @role
    @role = @new_role
    respond_to do |format|
      format.html { redirect_to(after_update_location, notice: role_change_message) }
      format.js
    end
  end

  def create_new_role_and_destroy_old_role
    @new_role = build_new_type
    authorize!(:create, @new_role)

    Role.transaction do
      @new_role.save && entry.destroy
    end
  end

  def build_new_type
    new_role = build_role
    new_role.attributes = permitted_params(@type)
    new_role.person_id = entry.person_id
    new_role.group_id = @group.id
    new_role
  end

  def copy_errors(new_role)
    entry.attributes = new_role.attributes.except('id')
    new_role.errors.each do |error|
      entry.errors.add(error.attribute, error.message)
    end
  end

  def build_entry
    @group = find_group
    # delete unused attributes
    model_params&.delete(:person)

    role = build_role
    role.group_id = @group.id
    build_person(role)

    role
  end

  def find_entry
    super.tap { |role| @type = role.class }
  end

  def build_role
    type = extract_model_attr(:type)
    start_at = extract_start_at
    return Role.new(convert_on: start_at) if type.blank?

    @type = @group.class.find_role_type!(type)

    if start_at&.future?
      FutureRole.new(convert_to: @type, convert_on: start_at, created_at: Time.zone.now)
    else
      @type.new(created_at: start_at)
    end
  end

  def build_person(role)
    person_attrs = extract_model_attr(:new_person) || ActionController::Parameters.new
    person_id = extract_model_attr(:person_id)
    if person_id.present?
      role.person_id = person_id
      role.person = Person.new unless role.person
    else
      attrs = person_attrs.permit(*PeopleController.permitted_attrs)
      role.person = Person.new(attrs)
    end
  end

  def permitted_params(role_type = entry.class)
    @permitted_params ||=
      begin
        permitted_attrs = role_type.used_attributes + [:convert_on]
        permitted_attrs -= [:deleted_at, :delete_on] unless can?(:destroy, @role)
        model_params.permit(permitted_attrs)
      end
  end

  def find_group
    id = extract_model_attr(:group_id)
    id ? Group.find(id) : parent
  end

  def extract_model_attr(attr)
    model_params&.fetch(attr, nil)
  end

  # A label for the current entry, including the model name, used for flash
  def full_entry_label(role = entry)
    translate(:full_entry_label, model_label: models_label(false),
                                 role: h(role),
                                 person: h(role.person),
                                 group: h(role.group)).html_safe
  end

  def role_change_message
    key = @group.id == @old_role.group.id ? :role_changed : :role_changed_to_group
    translate(key, full_entry_label: full_entry_label(@old_role), new_role: h(@role),
                   new_group: h(@group))
  end

  def after_create_location(new_person)
    return return_path if return_path.present?
    return new_group_role_path(entry.group_id) if params.key?(:add_another)
    return edit_group_person_path(entry.group_id, entry.person_id) if new_person &&
      entry.person.try(:persisted?)

    group_people_path(entry.group_id)
  end

  def after_update_location
    return group_person_path(entry.group_id, entry.person_id) unless entry.deleted?

    can?(:show, entry.person) ? person_path(entry.person_id) : group_path(parent)
  end

  def set_group_selection
    if can?(:create_in_subgroup, entry)
      @group_selection = @group.groups_in_same_layer.to_a
    end
  end

  def last_primary_group_role_deleted
    # only show warning if more than one group remains
    if @was_last_primary_group_role && entry.person.roles.select(:group_id).distinct.count > 1
      new_group = entry.person.primary_group
      flash[:alert] = t('roles.role_primary_group_changed', new_group: new_group.to_s)
    end
  end

  def remember_primary_group
    @was_last_primary_group_role =
      persons_last_primary_group_role?(entry)
  end

  def persons_last_primary_group_role?(role)
    if belongs_to_persons_primary_group?(role)
      group_roles = role.person.roles.where(group_id: role.group_id)
      return group_roles.size == 1
    end
    false
  end

  def belongs_to_persons_primary_group?(role)
    role.group_id == role.person.primary_group_id
  end

  def set_person_id
    @person_id = Role.with_deleted.find(params[:role_id]).person_id if params[:role_id]
  end

  def privacy_policy_param
    extract_model_attr(:new_person)&.fetch(:privacy_policy_accepted, nil)
  end

  def person
    entry.person
  end

  def group
    entry.group
  end

  def extract_start_at
    Date.parse(delete_model_param(:created_at) || delete_model_param(:convert_on))
  rescue TypeError, Date::Error
    nil
  end

  def delete_model_param(key)
    model_params&.delete(key).presence
  end
end
