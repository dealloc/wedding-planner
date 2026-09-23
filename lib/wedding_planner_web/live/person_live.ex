defmodule WeddingPlannerWeb.Live.PersonLive do
  @moduledoc """
  The per-person detail page (task 27; `DR-26` Q9): `/people/:id`, every `PER-02` field
  editable, this person's own activity history (`XC-11`), and delete (`XC-40`).
  Phone-first (`NFR-31`: "finding and viewing a person" is one of the four
  phone-quality-required flows) — default (narrow) `Layouts.app` width, a single
  stacked form, no wide-table assumptions.

  Follows `WeddingPlannerWeb.Live.EventsLive`'s `:edit` action pattern (`validate`/`save`
  form, `entity_history/1` fed from `WeddingPlanner.Log.Query.for_entity/2` and kept live
  via `:activity_entry`), except this page does not navigate away on save — it *is* the
  person's own page, not a transient edit flow, so a successful save simply stays here
  with a flash and a refreshed form.

  ## +1s (task 37, `PER-10`–`PER-16`, `DR-32`/`DR-34`)

  Whether `@person` is a +1 (`Person.plus_one?/1`, i.e. `host_id` set) branches this
  page's own rendering, not a separate LiveView:

    * A +1's page shows a "+1 of ⟨host⟩" link, a single-tap **Confirm** button (only
      while *possible*) and, while unnamed, a small **Name** form — each a single call to
      `WeddingPlanner.Guests` (`confirm_plus_one/2` / `name_plus_one/3`), rendered as
      siblings of `#person-form`, never nested inside it. The form itself drops the
      group/want/certainty inputs (not editable on a +1, `PER-15`) for a read-only block
      of the *inherited* values, read through `WeddingPlanner.Guests.PlusOne` — never
      from the +1's own `want_tier`/`certainty` columns (`DR-32`).
    * A host's page (any non-+1 person) adds a "+1s" list plus an add-+1 form
      (`Guests.add_plus_one/3`); its delete confirmation's `affected` already names the
      +1s via `Guests.person_deletion_effects/1` (`PER-16`).

  Live updates (`XC-01`) beyond "the viewed record itself changed" (already handled):
  a sibling +1 changing while viewing its host re-fetches the host's `:plus_ones`, and
  the host changing while viewing one of its unnamed +1s re-fetches the +1 (its display
  name and inherited values both read through the host). `DR-21`: no concurrent-edit
  indicator — a broadcast simply updates the assigns in place.
  """
  use WeddingPlannerWeb, :live_view

  import WeddingPlannerWeb.ActivityComponents, only: [entity_history: 1]

  alias WeddingPlanner.Guests
  alias WeddingPlanner.Guests.Group
  alias WeddingPlanner.Guests.Person
  alias WeddingPlanner.Guests.PlusOne
  alias WeddingPlanner.Log.Query, as: LogQuery
  alias WeddingPlanner.Realtime

  on_mount {WeddingPlannerWeb.Live.TimeZoneHook, :default}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Realtime.subscribe(:person)
      Realtime.subscribe(:activity_entry)
    end

    person = Guests.get_person!(id)

    socket =
      socket
      |> assign(:page_title, Person.display_name(person))
      |> assign(:person, person)
      |> assign(:groups, Guests.list_groups())
      |> assign(:form, to_form(Guests.change_person(person)))
      |> assign(:plus_ones, load_plus_ones(person))
      |> assign(:add_plus_one_form, add_plus_one_form(person))
      |> assign(:name_form, name_plus_one_form(person))
      |> assign(:confirming_delete, false)
      |> assign(:activity_entries, LogQuery.for_entity(:person, person.id))

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"person" => params}, socket) do
    form =
      socket.assigns.person
      |> Guests.change_person(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"person" => params}, socket) do
    scope = socket.assigns.current_scope

    case Guests.update_person(scope, socket.assigns.person, params) do
      {:ok, person} ->
        socket =
          socket
          |> refresh_view(person)
          |> put_flash(:info, "Person updated.")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("confirm_plus_one", _params, socket) do
    scope = socket.assigns.current_scope

    case Guests.confirm_plus_one(scope, socket.assigns.person) do
      {:ok, person} ->
        socket =
          socket
          |> refresh_view(person)
          |> put_flash(:info, "+1 confirmed.")

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, socket}
    end
  end

  def handle_event("validate_name_plus_one", %{"person" => params}, socket) do
    form =
      socket.assigns.person
      |> Guests.change_person(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :name_form, form)}
  end

  def handle_event("name_plus_one", %{"person" => params}, socket) do
    scope = socket.assigns.current_scope

    case Guests.name_plus_one(scope, socket.assigns.person, params) do
      {:ok, person} ->
        socket =
          socket
          |> refresh_view(person)
          |> assign(:name_form, name_plus_one_form(person))
          |> put_flash(:info, "+1 named.")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :name_form, to_form(changeset))}
    end
  end

  def handle_event("validate_add_plus_one", %{"person" => params}, socket) do
    host = socket.assigns.person

    form =
      host
      |> blank_plus_one_struct()
      |> Guests.change_person(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :add_plus_one_form, form)}
  end

  def handle_event("add_plus_one", %{"person" => params}, socket) do
    scope = socket.assigns.current_scope
    host = socket.assigns.person

    case Guests.add_plus_one(scope, host, params) do
      {:ok, _plus_one} ->
        refreshed = Guests.get_person!(host.id)

        socket =
          socket
          |> refresh_view(refreshed)
          |> assign(:add_plus_one_form, add_plus_one_form(refreshed))
          |> put_flash(:info, "+1 added.")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :add_plus_one_form, to_form(changeset))}
    end
  end

  def handle_event("confirm_delete", _params, socket) do
    {:noreply, assign(socket, :confirming_delete, true)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirming_delete, false)}
  end

  def handle_event("delete_confirmed", _params, socket) do
    scope = socket.assigns.current_scope
    {:ok, _} = Guests.delete_person(scope, socket.assigns.person)

    {:noreply,
     socket
     |> put_flash(:info, "Person deleted.")
     |> push_navigate(to: ~p"/people")}
  end

  @impl true
  def handle_info({Realtime, :person, {:deleted, id}}, socket) do
    cond do
      id == socket.assigns.person.id ->
        {:noreply,
         socket
         |> put_flash(:error, "This person was deleted.")
         |> push_navigate(to: ~p"/people")}

      Enum.any?(socket.assigns.plus_ones, &(&1.id == id)) ->
        {:noreply, update(socket, :plus_ones, &Enum.reject(&1, fn p -> p.id == id end))}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({Realtime, :person, {event, person}}, socket)
      when event in [:created, :updated] do
    viewed = socket.assigns.person

    cond do
      person.id == viewed.id ->
        {:noreply, refresh_view(socket, person)}

      Person.plus_one?(person) and person.host_id == viewed.id ->
        {:noreply, refresh_view(socket, Guests.get_person!(viewed.id))}

      Person.plus_one?(viewed) and viewed.host_id == person.id ->
        {:noreply, refresh_view(socket, Guests.get_person!(viewed.id))}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({Realtime, :activity_entry, {:created, entry}}, socket) do
    %{person: person} = socket.assigns

    if entry.entity_type == "person" and entry.entity_id == person.id do
      entry = LogQuery.preload_user(entry)
      {:noreply, update(socket, :activity_entries, &[entry | &1])}
    else
      {:noreply, socket}
    end
  end

  # -- helpers ---------------------------------------------------------------------------

  defp refresh_view(socket, %Person{} = person) do
    socket
    |> assign(:person, person)
    |> assign(:page_title, Person.display_name(person))
    |> assign(:form, to_form(Guests.change_person(person)))
    |> assign(:plus_ones, load_plus_ones(person))
  end

  # `DR-34`: a unit's +1s directly follow the host, ordered by id; `Person.display_name/1`
  # needs `:host` preloaded for an unnamed +1, which a bare `has_many :plus_ones` preload
  # does not nest — set explicitly here from the host struct we already have in hand.
  defp load_plus_ones(%Person{} = person) do
    person.plus_ones
    |> Enum.sort_by(& &1.id)
    |> Enum.map(&Map.put(&1, :host, person))
  end

  defp blank_plus_one_struct(%Person{} = host),
    do: %Person{host_id: host.id, plus_one_status: :possible}

  defp add_plus_one_form(%Person{} = host) do
    host
    |> blank_plus_one_struct()
    |> Guests.change_person(%{})
    |> to_form()
  end

  defp name_plus_one_form(%Person{} = person),
    do: person |> Guests.change_person(%{}) |> to_form()

  defp delete_confirm_title(%Person{} = person) do
    if Person.plus_one?(person) do
      "Remove '#{Person.display_name(person)}'?"
    else
      "Delete '#{Person.display_name(person)}'?"
    end
  end

  defp inherited_group_label(%Person{host: %Person{group: nil}}), do: "No group"
  defp inherited_group_label(%Person{host: %Person{group: %Group{name: name}}}), do: name

  defp age_label(:adult), do: "Adult"
  defp age_label(:child), do: "Child"

  defp want_label(:yes), do: "Yes"
  defp want_label(:maybe), do: "Maybe"
  defp want_label(:no), do: "No"
  defp want_label(:obligated), do: "Obligated"

  defp certainty_label(:certain), do: "Certain"
  defp certainty_label(:likely), do: "Likely"
  defp certainty_label(:uncertain), do: "Uncertain"

  defp plus_one_status_label(:possible), do: "Possible"
  defp plus_one_status_label(:confirmed), do: "Confirmed"

  # `DR-34`: +1 *possible* -> warn, *confirmed* -> good
  # (`.claude/design/ui-decisions.md` §2 semantic table).
  defp plus_one_status_tone(:possible), do: :warn
  defp plus_one_status_tone(:confirmed), do: :good

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <WeddingPlannerWeb.Live.TimeZoneHook.probe id="person-time-zone-probe" />

      <.header>
        {Person.display_name(@person)}
        <:actions>
          <.button navigate={~p"/people"} id="back-to-people">Back to people</.button>
        </:actions>
      </.header>

      <p :if={Person.plus_one?(@person)} id="person-host" class="mb-4 text-sm text-ink-soft">
        +1 of
        <.link
          navigate={~p"/people/#{@person.host_id}"}
          id="person-host-link"
          class="font-medium text-ink underline"
        >
          {Person.display_name(@person.host)}
        </.link>
      </p>

      <div
        :if={Person.plus_one?(@person)}
        class="mb-6 flex flex-wrap items-center gap-4"
        id="person-plus-one-actions"
      >
        <.status_pill
          id="person-plus-one-status-pill"
          label={plus_one_status_label(@person.plus_one_status)}
          tone={plus_one_status_tone(@person.plus_one_status)}
        />

        <.button
          :if={@person.plus_one_status == :possible}
          id="person-confirm-plus-one"
          variant="primary"
          phx-click="confirm_plus_one"
        >
          Confirm
        </.button>

        <.form
          :if={not Person.name_known?(@person)}
          for={@name_form}
          id="person-name-form"
          phx-change="validate_name_plus_one"
          phx-submit="name_plus_one"
          class="flex flex-wrap items-end gap-3"
        >
          <.input
            field={@name_form[:first_name]}
            type="text"
            label="First name"
            id="person-name-form-first-name"
          />
          <.input
            field={@name_form[:last_name]}
            type="text"
            label="Last name"
            id="person-name-form-last-name"
          />
          <.button variant="secondary" id="person-name-form-submit">Name</.button>
        </.form>
      </div>

      <.form for={@form} id="person-form" phx-change="validate" phx-submit="save" class="space-y-4">
        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <.input
            field={@form[:first_name]}
            type="text"
            label="First name"
            id="person-form-first-name"
          />
          <.input field={@form[:last_name]} type="text" label="Last name" id="person-form-last-name" />
        </div>

        <.input
          :if={not Person.plus_one?(@person)}
          field={@form[:group_id]}
          type="select"
          label="Group"
          prompt="No group"
          options={Enum.map(@groups, &{&1.name, &1.id})}
          id="person-form-group"
        />

        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <.input
            field={@form[:age_category]}
            type="select"
            label="Age category"
            options={Enum.map(Person.age_categories(), &{age_label(&1), &1})}
            id="person-form-age"
          />

          <.input
            :if={not Person.plus_one?(@person)}
            field={@form[:want_tier]}
            type="select"
            label="Want tier"
            options={Enum.map(Person.want_tiers(), &{want_label(&1), &1})}
            id="person-form-want"
          />

          <.input
            :if={Person.plus_one?(@person)}
            field={@form[:plus_one_status]}
            type="select"
            label="+1 status"
            options={Enum.map(Person.plus_one_statuses(), &{plus_one_status_label(&1), &1})}
            id="person-form-plus-one-status"
          />
        </div>

        <.input
          :if={not Person.plus_one?(@person)}
          field={@form[:certainty]}
          type="select"
          label="Certainty"
          options={Enum.map(Person.certainties(), &{certainty_label(&1), &1})}
          id="person-form-certainty"
        />

        <div
          :if={Person.plus_one?(@person)}
          id="person-inherited"
          class="rounded-field border border-line bg-surface p-4"
        >
          <p class="text-sm font-medium text-ink-soft">
            Inherited from {Person.display_name(@person.host)}
          </p>
          <dl class="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-3">
            <div id="person-inherited-group">
              <dt class="text-xs font-medium tracking-wide text-ink-faint uppercase">Group</dt>
              <dd class="mt-0.5 text-sm text-ink">{inherited_group_label(@person)}</dd>
            </div>
            <div id="person-inherited-want">
              <dt class="text-xs font-medium tracking-wide text-ink-faint uppercase">Want tier</dt>
              <dd class="mt-0.5 text-sm text-ink">{want_label(PlusOne.want_tier(@person))}</dd>
            </div>
            <div id="person-inherited-certainty">
              <dt class="text-xs font-medium tracking-wide text-ink-faint uppercase">Certainty</dt>
              <dd class="mt-0.5 text-sm text-ink">{certainty_label(PlusOne.certainty(@person))}</dd>
            </div>
          </dl>
        </div>

        <.input field={@form[:notes]} type="textarea" label="Notes" id="person-form-notes" />

        <.button variant="primary" id="person-form-submit">Save person</.button>
      </.form>

      <div :if={not Person.plus_one?(@person)} class="mt-8 space-y-3" id="person-plus-ones">
        <.header>+1s</.header>

        <ul :if={@plus_ones != []} id="person-plus-ones-list" class="space-y-2">
          <li
            :for={plus_one <- @plus_ones}
            class="flex items-center justify-between gap-3 rounded-field border border-line p-3"
          >
            <.link
              navigate={~p"/people/#{plus_one.id}"}
              id={"person-plus-one-#{plus_one.id}"}
              class={[
                "text-sm font-medium",
                if(Person.name_known?(plus_one), do: "text-ink", else: "text-ink-soft italic")
              ]}
            >
              {Person.display_name(plus_one)}
            </.link>
            <.status_pill
              id={"person-plus-one-#{plus_one.id}-status"}
              label={plus_one_status_label(plus_one.plus_one_status)}
              tone={plus_one_status_tone(plus_one.plus_one_status)}
            />
          </li>
        </ul>
        <p :if={@plus_ones == []} class="text-sm text-ink-faint">No +1s yet.</p>

        <.form
          for={@add_plus_one_form}
          id="person-add-plus-one-form"
          phx-change="validate_add_plus_one"
          phx-submit="add_plus_one"
          class="space-y-3 rounded-field border border-line p-4"
        >
          <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <.input
              field={@add_plus_one_form[:first_name]}
              type="text"
              label="First name"
              id="person-add-plus-one-first-name"
            />
            <.input
              field={@add_plus_one_form[:last_name]}
              type="text"
              label="Last name"
              id="person-add-plus-one-last-name"
            />
          </div>
          <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <.input
              field={@add_plus_one_form[:plus_one_status]}
              type="select"
              label="+1 status"
              options={Enum.map(Person.plus_one_statuses(), &{plus_one_status_label(&1), &1})}
              id="person-add-plus-one-status"
            />
            <.input
              field={@add_plus_one_form[:age_category]}
              type="select"
              label="Age category"
              options={Enum.map(Person.age_categories(), &{age_label(&1), &1})}
              id="person-add-plus-one-age"
            />
          </div>
          <.button variant="primary" id="person-add-plus-one-submit">Add +1</.button>
        </.form>
      </div>

      <div class="mt-8 space-y-2">
        <.header>Delete this person</.header>
        <.button variant="destructive" id="person-delete" phx-click="confirm_delete">
          Delete person
        </.button>

        <.destructive_confirm
          :if={@confirming_delete}
          id="person-delete-confirm"
          title={delete_confirm_title(@person)}
          body="This cannot be undone."
          affected={Guests.person_deletion_effects(@person)}
          confirm="delete_confirmed"
          cancel="cancel_delete"
        />
      </div>

      <div class="mt-8">
        <.header>History</.header>
        <.entity_history
          id="person-history"
          entity={{:person, @person.id}}
          entries={@activity_entries}
          time_zone={@time_zone}
        />
      </div>
    </Layouts.app>
    """
  end
end
