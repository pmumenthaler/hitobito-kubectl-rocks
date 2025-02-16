# frozen_string_literal: true

#  Copyright (c) 2023, Pfadibewegung Schweiz. This file is part of
#  hitobito and licensed under the Affero General Public License version 3
#  or later. See the COPYING file at the top-level directory or at
#  https://github.com/hitobito/hitobito.

class People::CleanupFinder

  def run
    people_to_cleanup_scope.distinct
  end

  private

  def people_to_cleanup_scope
    scope = base_scope.joins('LEFT JOIN roles ON roles.person_id = people.id')

    scope = without_any_roles_or_with_roles_outside_cutoff(scope)
    scope = without_participating_in_future_events(scope)
    scope = with_current_sign_in_at_outside_cutoff(scope)

    scope
  end

  def base_scope
    Person.all.where.not(id: Person.root.id)
  end

  def no_roles_exist
    any_roles.arel.exists.not
  end

  def any_roles
    Role.with_deleted.where('roles.person_id = people.id')
  end

  def without_any_roles_or_with_roles_outside_cutoff(scope)
    without_any_roles(scope).or(with_roles_outside_cutoff(scope))
  end

  def without_any_roles(scope)
    scope.where(no_roles_exist)
  end

  def with_roles_outside_cutoff(scope)
    scope.where('roles.deleted_at <= ?', last_role_deleted_at)
  end

  def without_participating_in_future_events(scope)
    scope.where(not_participating_in_future_events)
  end

  def with_current_sign_in_at_outside_cutoff(scope)
    scope.where('people.current_sign_in_at <= ? OR people.current_sign_in_at IS NULL',
                current_sign_in_at)
  end

  def last_role_deleted_at
    Settings.people.cleanup_cutoff_duration.regarding_roles.months.ago
  end

  def people_without_any_roles
    base_scope.where.not(id: Role.with_deleted.pluck(:person_id)).distinct
  end

  def not_participating_in_future_events
    Event.joins(:dates, :participations)
      .where('event_dates.start_at > :now OR event_dates.finish_at > :now', now: Time.zone.now)
      .where('event_participations.person_id = people.id').arel.exists.not
  end

  def current_sign_in_at
    Settings.people.cleanup_cutoff_duration.regarding_current_sign_in_at.months.ago
  end
end
