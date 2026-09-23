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
  """
  use WeddingPlannerWeb, :live_view

  import WeddingPlannerWeb.ActivityComponents, only: [entity_history: 1]

  alias WeddingPlanner.Guests
  alias WeddingPlanner.Guests.Person
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
          |> assign(:person, person)
          |> assign(:form, to_form(Guests.change_person(person)))
          |> put_flash(:info, "Person updated.")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
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
    if id == socket.assigns.person.id do
      {:noreply,
       socket
       |> put_flash(:error, "This person was deleted.")
       |> push_navigate(to: ~p"/people")}
    else
      {:noreply, socket}
    end
  end

  def handle_info({Realtime, :person, {event, person}}, socket)
      when event in [:created, :updated] do
    if person.id == socket.assigns.person.id do
      socket =
        socket
        |> assign(:person, person)
        |> assign(:page_title, Person.display_name(person))
        |> assign(:form, to_form(Guests.change_person(person)))

      {:noreply, socket}
    else
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

  defp age_label(:adult), do: "Adult"
  defp age_label(:child), do: "Child"

  defp want_label(:yes), do: "Yes"
  defp want_label(:maybe), do: "Maybe"
  defp want_label(:no), do: "No"
  defp want_label(:obligated), do: "Obligated"

  defp certainty_label(:certain), do: "Certain"
  defp certainty_label(:likely), do: "Likely"
  defp certainty_label(:uncertain), do: "Uncertain"

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
            field={@form[:want_tier]}
            type="select"
            label="Want tier"
            options={Enum.map(Person.want_tiers(), &{want_label(&1), &1})}
            id="person-form-want"
          />
        </div>

        <.input
          field={@form[:certainty]}
          type="select"
          label="Certainty"
          options={Enum.map(Person.certainties(), &{certainty_label(&1), &1})}
          id="person-form-certainty"
        />

        <.input field={@form[:notes]} type="textarea" label="Notes" id="person-form-notes" />

        <.button variant="primary" id="person-form-submit">Save person</.button>
      </.form>

      <div class="mt-8 space-y-2">
        <.header>Delete this person</.header>
        <.button variant="destructive" id="person-delete" phx-click="confirm_delete">
          Delete person
        </.button>

        <.destructive_confirm
          :if={@confirming_delete}
          id="person-delete-confirm"
          title={"Delete '#{Person.display_name(@person)}'?"}
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
