defmodule WeddingPlanner.CategoriesTest do
  @moduledoc """
  `docs/modules/offers-and-comparison.md` `CST-01` through `CST-06`, `D-34`, `DR-26`
  Q11/Q12/Q14, `DR-18`, `DR-23`, `XC-01`, `XC-02`, `XC-10`, `XC-12` — the categories and
  services context, slice C1's data layer.
  """
  use WeddingPlanner.DataCase, async: true

  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Categories
  alias WeddingPlanner.Categories.Service
  alias WeddingPlanner.Log.EntityRef
  alias WeddingPlanner.Log.Entry
  alias WeddingPlanner.Log.Query
  alias WeddingPlanner.Realtime
  alias WeddingPlanner.Tasks
  alias WeddingPlanner.Valuation.Snapshot
  alias WeddingPlannerWeb.Format

  setup do
    user = insert_user!("Wannes")
    %{user: user, scope: Scope.for_user(user)}
  end

  # -- Categories ----------------------------------------------------------------------

  describe "create_category/2 (CST-01, CST-05)" do
    test "creates a category with no target", %{scope: scope} do
      assert {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})

      assert category.name == "Venue"
      assert is_nil(category.target)
    end

    test "requires a name", %{scope: scope} do
      assert {:error, changeset} = Categories.create_category(scope, %{"name" => ""})
      assert "can't be blank" in errors_on(changeset).name
    end

    test "trims the name", %{scope: scope} do
      assert {:ok, category} = Categories.create_category(scope, %{"name" => "  Venue  "})
      assert category.name == "Venue"
    end

    test "is appended after the current last category (CST-01)", %{scope: scope} do
      {:ok, first} = Categories.create_category(scope, %{"name" => "Venue"})
      {:ok, second} = Categories.create_category(scope, %{"name" => "Catering"})

      assert second.sort_order > first.sort_order
    end

    test "sort_order is not settable through user attrs", %{scope: scope} do
      assert {:ok, category} =
               Categories.create_category(scope, %{"name" => "Venue", "sort_order" => "999"})

      assert category.sort_order != 999
    end

    test "logs the create (XC-10)", %{scope: scope, user: user} do
      assert {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})

      entry = Repo.one!(Entry)
      assert entry.user_id == user.id
      assert entry.entity_type == "category"
      assert entry.entity_id == category.id
      assert entry.description == "Wannes created category 'Venue'"
    end

    test "broadcasts {:created, category} (XC-01)", %{scope: scope} do
      Realtime.subscribe(:category)
      assert {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})

      assert_received {Realtime, :category, {:created, ^category}}
    end
  end

  describe "list_categories/0 (CST-01)" do
    test "renders in manual sort order", %{scope: scope} do
      {:ok, a} = Categories.create_category(scope, %{"name" => "A"})
      {:ok, b} = Categories.create_category(scope, %{"name" => "B"})
      :ok = Categories.move_category(scope, b, :up)

      assert Enum.map(Categories.list_categories(), & &1.id) == [b.id, a.id]
    end
  end

  describe "category target money handling (CST-01, DR-23, DR-18)" do
    setup %{scope: scope} do
      {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})
      %{category: category}
    end

    test "\"2.500\" stores € 2.500,00", %{scope: scope, category: category} do
      assert {:ok, updated} =
               Categories.update_category(scope, category, %{"target_input" => "2.500"})

      assert Format.money(updated.target) == "€ 2.500,00"
    end

    test "\"2500,00\" stores the same amount", %{scope: scope, category: category} do
      assert {:ok, updated} =
               Categories.update_category(scope, category, %{"target_input" => "2500,00"})

      assert Format.money(updated.target) == "€ 2.500,00"
    end

    test "\"1500.50\" is refused with the comma message (DR-18 trap)", %{
      scope: scope,
      category: category
    } do
      assert {:error, changeset} =
               Categories.update_category(scope, category, %{"target_input" => "1500.50"})

      assert "Use a comma for the decimal part (cents) — for example 45000,50, not 45000.50." in errors_on(
               changeset
             ).target_input
    end

    test "\"\" clears the target back to unset", %{scope: scope, category: category} do
      {:ok, with_target} =
        Categories.update_category(scope, category, %{"target_input" => "1000"})

      assert %Money{} = with_target.target

      assert {:ok, cleared} =
               Categories.update_category(scope, with_target, %{"target_input" => ""})

      assert cleared.target == nil
    end

    test "omitting the key leaves the target untouched", %{scope: scope, category: category} do
      {:ok, with_target} =
        Categories.update_category(scope, category, %{"target_input" => "1000"})

      assert {:ok, unchanged} =
               Categories.update_category(scope, with_target, %{"name" => "Reception venue"})

      assert unchanged.target == with_target.target
      assert unchanged.name == "Reception venue"
    end

    test "\"0\" is a valid, accepted target", %{scope: scope, category: category} do
      assert {:ok, updated} =
               Categories.update_category(scope, category, %{"target_input" => "0"})

      assert Format.money(updated.target) == "€ 0,00"
    end
  end

  describe "update_category/3 per-field logging (XC-10)" do
    setup %{scope: scope} do
      {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})
      %{category: category}
    end

    test "logs the name change", %{scope: scope, category: category} do
      {:ok, _updated} =
        Categories.update_category(scope, category, %{"name" => "Reception venue"})

      entries = Repo.all(Entry) |> Enum.reject(&(&1.description =~ "created"))
      assert [entry] = entries

      assert entry.description == "Wannes changed the name of 'Venue': Venue → Reception venue"
    end

    test "logs the target change, 'Not set' for an unset old value", %{
      scope: scope,
      category: category
    } do
      {:ok, _updated} =
        Categories.update_category(scope, category, %{"target_input" => "2.500,00"})

      entries = Repo.all(Entry) |> Enum.reject(&(&1.description =~ "created"))
      assert [entry] = entries

      assert entry.description ==
               "Wannes changed the target of 'Venue': Not set → € 2.500,00"
    end

    test "logs nothing extra when nothing changed", %{scope: scope, category: category} do
      {:ok, _updated} = Categories.update_category(scope, category, %{"name" => category.name})

      entries = Repo.all(Entry) |> Enum.reject(&(&1.description =~ "created"))
      assert entries == []
    end

    test "broadcasts {:updated, category} (XC-01)", %{scope: scope, category: category} do
      Realtime.subscribe(:category)

      assert {:ok, updated} =
               Categories.update_category(scope, category, %{"name" => "Reception"})

      assert_received {Realtime, :category, {:updated, ^updated}}
    end
  end

  describe "move_category/3 (CST-01, XC-12)" do
    setup %{scope: scope} do
      {:ok, a} = Categories.create_category(scope, %{"name" => "A"})
      {:ok, b} = Categories.create_category(scope, %{"name" => "B"})
      {:ok, c} = Categories.create_category(scope, %{"name" => "C"})
      %{a: a, b: b, c: c}
    end

    test "moving the middle category up swaps it with the first", %{
      scope: scope,
      a: a,
      b: b,
      c: c
    } do
      assert :ok = Categories.move_category(scope, b, :up)
      assert Enum.map(Categories.list_categories(), & &1.id) == [b.id, a.id, c.id]
    end

    test "moving the middle category down swaps it with the last", %{
      scope: scope,
      a: a,
      b: b,
      c: c
    } do
      assert :ok = Categories.move_category(scope, b, :down)
      assert Enum.map(Categories.list_categories(), & &1.id) == [a.id, c.id, b.id]
    end

    test "the reordered position persists", %{scope: scope, a: a, b: b, c: c} do
      :ok = Categories.move_category(scope, c, :up)
      assert Enum.map(Categories.list_categories(), & &1.id) == [a.id, c.id, b.id]
    end

    test "moving the first category up is a no-op", %{scope: scope, a: a, b: b, c: c} do
      assert :ok = Categories.move_category(scope, a, :up)
      assert Enum.map(Categories.list_categories(), & &1.id) == [a.id, b.id, c.id]
    end

    test "moving the last category down is a no-op", %{scope: scope, a: a, b: b, c: c} do
      assert :ok = Categories.move_category(scope, c, :down)
      assert Enum.map(Categories.list_categories(), & &1.id) == [a.id, b.id, c.id]
    end

    test "logs one summary plus one child per affected category (XC-12)", %{
      scope: scope,
      a: a,
      b: b
    } do
      :ok = Categories.move_category(scope, b, :up)

      entries = Repo.all(Entry) |> Enum.reject(&(&1.description =~ "created"))
      {[summary], children} = Enum.split_with(entries, &is_nil(&1.entity_type))

      assert summary.description == "Wannes moved 'B' up in the category order"
      assert length(children) == 2
      assert Enum.all?(children, &(&1.parent_id == summary.id))
      assert Enum.sort(Enum.map(children, & &1.entity_id)) == Enum.sort([a.id, b.id])
    end

    test "a boundary move logs and broadcasts nothing", %{scope: scope, a: a} do
      Realtime.subscribe(:category)
      assert :ok = Categories.move_category(scope, a, :up)

      assert Repo.all(Entry) |> Enum.reject(&(&1.description =~ "created")) == []
      refute_received {Realtime, :category, {:updated, _}}
    end
  end

  describe "delete_category/2 (DR-26 Q11)" do
    setup %{scope: scope} do
      {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})
      {:ok, s1} = Categories.create_service(scope, category, %{"name" => "Catering"})
      {:ok, s2} = Categories.create_service(scope, category, %{"name" => "Sound"})
      %{category: category, s1: s1, s2: s2}
    end

    test "category_deletion_blockers/1 is empty (no offers/invoices exist yet)", %{
      category: category
    } do
      assert Categories.category_deletion_blockers(category) == []
    end

    test "category_deletion_effects/1 counts services", %{category: category} do
      assert Categories.category_deletion_effects(category) == [%{label: "2 services", count: 2}]
    end

    test "deletes the category and every one of its services", %{
      scope: scope,
      category: category,
      s1: s1,
      s2: s2
    } do
      assert {:ok, _} = Categories.delete_category(scope, category)

      assert_raise Ecto.NoResultsError, fn -> Categories.get_category!(category.id) end
      assert_raise Ecto.NoResultsError, fn -> Categories.get_service!(s1.id) end
      assert_raise Ecto.NoResultsError, fn -> Categories.get_service!(s2.id) end
    end

    test "logs one summary, a child per deleted service, and the category's own entry (XC-12)",
         %{scope: scope, category: category, s1: s1, s2: s2} do
      {:ok, _} = Categories.delete_category(scope, category)

      entries = Repo.all(Entry) |> Enum.reject(&(&1.description =~ "created"))
      summary = Enum.find(entries, &is_nil(&1.entity_type))
      assert summary.description == "Wannes deleted category 'Venue' (2 services)"

      service_entries = Enum.filter(entries, &(&1.entity_type == "service"))
      assert length(service_entries) == 2
      assert Enum.all?(service_entries, &(&1.parent_id == summary.id))
      assert Enum.sort(Enum.map(service_entries, & &1.entity_id)) == Enum.sort([s1.id, s2.id])

      category_entry = Enum.find(entries, &(&1.entity_type == "category"))
      assert category_entry.parent_id == summary.id
      assert category_entry.description == "Wannes deleted category 'Venue'"
    end

    test "each deleted service's own history shows its deletion", %{
      scope: scope,
      category: category,
      s1: s1
    } do
      {:ok, _} = Categories.delete_category(scope, category)

      history = Query.for_entity(:service, s1.id)

      assert Enum.any?(
               history,
               &(&1.description == "Wannes deleted service 'Catering' (category 'Venue' deleted)")
             )
    end

    test "broadcasts {:deleted, id} for every service and the category (XC-01)", %{
      scope: scope,
      category: category,
      s1: s1,
      s2: s2
    } do
      Realtime.subscribe(:category)
      Realtime.subscribe(:service)

      {:ok, deleted} = Categories.delete_category(scope, category)

      assert_received {Realtime, :service, {:deleted, first_deleted}}
      assert_received {Realtime, :service, {:deleted, second_deleted}}
      assert Enum.sort([first_deleted, second_deleted]) == Enum.sort([s1.id, s2.id])

      deleted_id = deleted.id
      assert_received {Realtime, :category, {:deleted, ^deleted_id}}
    end
  end

  describe "delete_category/2 — task link (task 32, DR-26 Q11/Q18)" do
    setup %{scope: scope} do
      {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})
      %{category: category}
    end

    test "category_deletion_effects/1 has no task-link entry when nothing links to it", %{
      category: category
    } do
      assert Categories.category_deletion_effects(category) == [%{label: "0 services", count: 0}]
    end

    test "category_deletion_effects/1 appends the task-link entry when a task links to it", %{
      scope: scope,
      category: category
    } do
      {:ok, _task} =
        Tasks.create_task(scope, %{"title" => "Book florist", "link_category_id" => category.id})

      assert Categories.category_deletion_effects(category) == [
               %{label: "0 services", count: 0},
               %{label: "1 task linked to this category (link removed)", count: 1}
             ]
    end

    test "a task linked to the category is not a deletion blocker", %{
      scope: scope,
      category: category
    } do
      {:ok, _task} =
        Tasks.create_task(scope, %{"title" => "Book florist", "link_category_id" => category.id})

      assert Categories.category_deletion_blockers(category) == []
    end

    test "deleting the category clears the task's link, logs it as a child of the deletion summary, and the task's own history shows why",
         %{scope: scope, category: category} do
      {:ok, task} =
        Tasks.create_task(scope, %{"title" => "Book florist", "link_category_id" => category.id})

      assert {:ok, _} = Categories.delete_category(scope, category)

      reloaded = Tasks.get_task!(task.id)
      assert is_nil(reloaded.link_category_id)

      entries = Repo.all(Entry) |> Enum.reject(&(&1.description =~ "created"))
      summary = Enum.find(entries, &is_nil(&1.entity_type))
      assert summary.description == "Wannes deleted category 'Venue' (0 services)"

      task_entry = Enum.find(entries, &(&1.entity_type == "task"))
      assert task_entry.parent_id == summary.id

      assert task_entry.description ==
               "Wannes removed the link from 'Book florist' to category 'Venue' (category deleted)"

      history = Query.for_entity(:task, task.id)
      assert Enum.any?(history, &(&1.id == task_entry.id))
    end

    test "broadcasts {:updated, task} for every detached task (XC-01)", %{
      scope: scope,
      category: category
    } do
      {:ok, task} =
        Tasks.create_task(scope, %{"title" => "Book florist", "link_category_id" => category.id})

      Realtime.subscribe(:task)
      {:ok, _} = Categories.delete_category(scope, category)

      task_id = task.id
      assert_received {Realtime, :task, {:updated, %{id: ^task_id, link_category_id: nil}}}
    end

    test "a raw Repo.delete of a category a task links to raises (FK enforced)", %{
      scope: scope,
      category: category
    } do
      {:ok, _task} =
        Tasks.create_task(scope, %{"title" => "Book florist", "link_category_id" => category.id})

      assert_raise Ecto.ConstraintError, fn -> Repo.delete(category) end
    end
  end

  # -- Services --------------------------------------------------------------------------

  describe "create_service/3 (CST-02)" do
    setup %{scope: scope} do
      {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})
      %{category: category}
    end

    test "creates a service defaulting to nice-to-have", %{scope: scope, category: category} do
      assert {:ok, service} = Categories.create_service(scope, category, %{"name" => "Catering"})

      assert service.name == "Catering"
      assert service.wanted_priority == :nice_to_have
      assert service.category_id == category.id
    end

    test "requires a name", %{scope: scope, category: category} do
      assert {:error, changeset} = Categories.create_service(scope, category, %{"name" => ""})
      assert "can't be blank" in errors_on(changeset).name
    end

    test "is appended after the current last service in its category", %{
      scope: scope,
      category: category
    } do
      {:ok, first} = Categories.create_service(scope, category, %{"name" => "Catering"})
      {:ok, second} = Categories.create_service(scope, category, %{"name" => "Sound"})

      assert second.sort_order > first.sort_order
    end

    test "logs the create (XC-10)", %{scope: scope, category: category, user: user} do
      assert {:ok, service} = Categories.create_service(scope, category, %{"name" => "Catering"})

      entry = Repo.all(Entry) |> Enum.find(&(&1.entity_type == "service"))
      assert entry.user_id == user.id
      assert entry.entity_id == service.id
      assert entry.description == "Wannes created service 'Catering' in 'Venue'"
    end

    test "broadcasts {:created, service} (XC-01)", %{scope: scope, category: category} do
      Realtime.subscribe(:service)
      assert {:ok, service} = Categories.create_service(scope, category, %{"name" => "Catering"})

      assert_received {Realtime, :service, {:created, ^service}}
    end
  end

  describe "service name uniqueness within a category (CST-04, DR-26 Q14)" do
    setup %{scope: scope} do
      {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})
      {:ok, service} = Categories.create_service(scope, category, %{"name" => "Café"})
      %{category: category, service: service}
    end

    test "rejects a case-insensitive, Unicode-aware duplicate in the same category, naming the clash",
         %{scope: scope, category: category} do
      assert {:error, changeset} =
               Categories.create_service(scope, category, %{"name" => "CAFÉ"})

      assert "is already used by 'Café' in this category — merge instead?" in errors_on(changeset).name
    end

    test "the same name is fine in a different category", %{scope: scope} do
      {:ok, other_category} = Categories.create_category(scope, %{"name" => "Catering"})

      assert {:ok, service} =
               Categories.create_service(scope, other_category, %{"name" => "Café"})

      assert service.name == "Café"
    end

    test "a rename to another existing service's name fails, naming the clashing service", %{
      scope: scope,
      category: category
    } do
      {:ok, sound} = Categories.create_service(scope, category, %{"name" => "Sound"})

      assert {:error, changeset} = Categories.update_service(scope, sound, %{"name" => "café"})

      assert "is already used by 'Café' in this category — merge instead?" in errors_on(changeset).name
    end
  end

  describe "update_service/3 per-field logging (XC-10)" do
    setup %{scope: scope} do
      {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})
      {:ok, service} = Categories.create_service(scope, category, %{"name" => "Catering"})
      %{category: category, service: service}
    end

    test "logs a rename", %{scope: scope, service: service} do
      {:ok, _updated} = Categories.update_service(scope, service, %{"name" => "Catering & Bar"})

      entries = Repo.all(Entry) |> Enum.reject(&(&1.description =~ "created"))
      assert [entry] = entries

      assert entry.description ==
               "Wannes changed the name of 'Catering' in Venue: Catering → Catering & Bar"
    end

    test "logs a wanted priority change with labels", %{scope: scope, service: service} do
      {:ok, _updated} =
        Categories.update_service(scope, service, %{"wanted_priority" => "must_have"})

      entries = Repo.all(Entry) |> Enum.reject(&(&1.description =~ "created"))
      assert [entry] = entries

      assert entry.description ==
               "Wannes changed the wanted priority of 'Catering' in Venue: Nice-to-have → Must-have"
    end

    test "broadcasts {:updated, service} (XC-01)", %{scope: scope, service: service} do
      Realtime.subscribe(:service)

      assert {:ok, updated} =
               Categories.update_service(scope, service, %{"name" => "Catering & Bar"})

      assert_received {Realtime, :service, {:updated, ^updated}}
    end
  end

  describe "move_service/3 (CST-02, XC-12)" do
    setup %{scope: scope} do
      {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})
      {:ok, a} = Categories.create_service(scope, category, %{"name" => "A"})
      {:ok, b} = Categories.create_service(scope, category, %{"name" => "B"})
      {:ok, c} = Categories.create_service(scope, category, %{"name" => "C"})
      %{category: category, a: a, b: b, c: c}
    end

    test "moving the middle service up swaps it with the first", %{
      scope: scope,
      category: category,
      a: a,
      b: b,
      c: c
    } do
      assert :ok = Categories.move_service(scope, b, :up)
      assert Enum.map(Categories.list_services(category), & &1.id) == [b.id, a.id, c.id]
    end

    test "moving the middle service down swaps it with the last", %{
      scope: scope,
      category: category,
      a: a,
      b: b,
      c: c
    } do
      assert :ok = Categories.move_service(scope, b, :down)
      assert Enum.map(Categories.list_services(category), & &1.id) == [a.id, c.id, b.id]
    end

    test "moving the first service up is a no-op", %{scope: scope, category: category, a: a} do
      assert :ok = Categories.move_service(scope, a, :up)
      assert hd(Categories.list_services(category)).id == a.id
    end

    test "moving the last service down is a no-op", %{scope: scope, category: category, c: c} do
      assert :ok = Categories.move_service(scope, c, :down)
      assert List.last(Categories.list_services(category)).id == c.id
    end

    test "logs one summary plus one child per affected service (XC-12)", %{
      scope: scope,
      a: a,
      b: b
    } do
      :ok = Categories.move_service(scope, b, :up)

      entries = Repo.all(Entry) |> Enum.reject(&(&1.description =~ "created"))
      {[summary], children} = Enum.split_with(entries, &is_nil(&1.entity_type))

      assert summary.description == "Wannes moved 'B' up in Venue"
      assert length(children) == 2
      assert Enum.all?(children, &(&1.parent_id == summary.id))
      assert Enum.sort(Enum.map(children, & &1.entity_id)) == Enum.sort([a.id, b.id])
    end

    test "never reorders another category's services", %{scope: scope, a: a} do
      {:ok, other_category} = Categories.create_category(scope, %{"name" => "Catering"})
      {:ok, x} = Categories.create_service(scope, other_category, %{"name" => "X"})
      {:ok, y} = Categories.create_service(scope, other_category, %{"name" => "Y"})

      :ok = Categories.move_service(scope, a, :down)

      assert Enum.map(Categories.list_services(other_category), & &1.id) == [x.id, y.id]
    end
  end

  describe "service_line_count/1 (DR-26 Q12)" do
    test "is 0 today — no offer line schema exists yet", %{scope: scope} do
      {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})
      {:ok, service} = Categories.create_service(scope, category, %{"name" => "Catering"})

      assert Categories.service_line_count(service) == 0
    end
  end

  describe "delete_service/2 (CST-06, D-34, DR-26 Q12)" do
    setup %{scope: scope} do
      {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})
      {:ok, service} = Categories.create_service(scope, category, %{"name" => "Catering"})
      %{category: category, service: service}
    end

    test "deletes a service with no offer lines", %{scope: scope, service: service} do
      assert {:ok, _} = Categories.delete_service(scope, service)
      assert_raise Ecto.NoResultsError, fn -> Categories.get_service!(service.id) end
    end

    test "logs the delete and broadcasts {:deleted, id}", %{scope: scope, service: service} do
      Realtime.subscribe(:service)
      assert {:ok, deleted} = Categories.delete_service(scope, service)

      entry =
        Repo.all(Entry) |> Enum.find(&(&1.description == "Wannes deleted service 'Catering'"))

      assert entry
      assert entry.entity_id == service.id

      deleted_id = deleted.id
      assert_received {Realtime, :service, {:deleted, ^deleted_id}}
    end

    test "refuses and deletes nothing when service_line_count/1 is positive (test seam for slice C2)",
         %{scope: scope, service: service} do
      Application.put_env(:wedding_planner, :service_line_count_fun, fn _service -> 3 end)
      on_exit(fn -> Application.delete_env(:wedding_planner, :service_line_count_fun) end)

      assert {:error, :has_lines} = Categories.delete_service(scope, service)
      assert %Service{} = Categories.get_service!(service.id)
    end
  end

  describe "merge_services/3 (CST-04, DR-26 Q14)" do
    setup %{scope: scope} do
      {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})

      {:ok, survivor} =
        Categories.create_service(scope, category, %{
          "name" => "Sound",
          "wanted_priority" => "must_have"
        })

      {:ok, absorbed} = Categories.create_service(scope, category, %{"name" => "Sound system"})

      %{category: category, survivor: survivor, absorbed: absorbed}
    end

    test "the survivor keeps its own name, wanted priority and position; the absorbed service is deleted",
         %{scope: scope, survivor: survivor, absorbed: absorbed} do
      assert {:ok, merged} = Categories.merge_services(scope, absorbed, survivor)

      assert merged.id == survivor.id
      assert merged.name == "Sound"
      assert merged.wanted_priority == :must_have
      assert merged.sort_order == survivor.sort_order

      assert_raise Ecto.NoResultsError, fn -> Categories.get_service!(absorbed.id) end
    end

    test "logs a summary and a child entry on each service", %{
      scope: scope,
      survivor: survivor,
      absorbed: absorbed
    } do
      {:ok, _} = Categories.merge_services(scope, absorbed, survivor)

      entries = Repo.all(Entry) |> Enum.reject(&(&1.description =~ "created"))
      summary = Enum.find(entries, &is_nil(&1.entity_type))
      assert summary.description == "Wannes merged 'Sound system' into 'Sound' in Venue"

      children = Enum.filter(entries, &(not is_nil(&1.entity_type)))
      assert length(children) == 2
      assert Enum.all?(children, &(&1.parent_id == summary.id))

      assert Enum.sort(Enum.map(children, & &1.entity_id)) ==
               Enum.sort([survivor.id, absorbed.id])
    end

    test "each service's own history shows the merge", %{
      scope: scope,
      survivor: survivor,
      absorbed: absorbed
    } do
      {:ok, _} = Categories.merge_services(scope, absorbed, survivor)

      survivor_history = Query.for_entity(:service, survivor.id)
      absorbed_history = Query.for_entity(:service, absorbed.id)

      assert Enum.any?(
               survivor_history,
               &(&1.description == "Wannes merged 'Sound system' into 'Sound' in Venue")
             )

      assert Enum.any?(
               absorbed_history,
               &(&1.description == "Wannes merged 'Sound system' into 'Sound' in Venue")
             )
    end

    test "refuses to merge services from different categories, deleting nothing", %{
      scope: scope,
      survivor: survivor
    } do
      {:ok, other_category} = Categories.create_category(scope, %{"name" => "Catering"})

      {:ok, other_service} =
        Categories.create_service(scope, other_category, %{"name" => "Buffet"})

      assert {:error, :different_categories} =
               Categories.merge_services(scope, other_service, survivor)

      assert %Service{} = Categories.get_service!(other_service.id)
    end

    test "broadcasts {:deleted, id} for the absorbed service", %{
      scope: scope,
      survivor: survivor,
      absorbed: absorbed
    } do
      Realtime.subscribe(:service)
      {:ok, _} = Categories.merge_services(scope, absorbed, survivor)

      absorbed_id = absorbed.id
      assert_received {Realtime, :service, {:deleted, ^absorbed_id}}
    end
  end

  describe "WeddingPlanner.Log.EntityRef 'category' and 'service' resolvers (XC-10)" do
    setup %{scope: scope} do
      {:ok, category} = Categories.create_category(scope, %{"name" => "Venue"})
      {:ok, service} = Categories.create_service(scope, category, %{"name" => "Catering"})
      %{category: category, service: service}
    end

    test "an existing category resolves to a navigable link to its own page", %{
      category: category
    } do
      assert {:link, "Venue", "/categories/" <> id} = EntityRef.resolve("category", category.id)
      assert id == to_string(category.id)
    end

    test "a deleted category degrades to text" do
      assert {:text, _label} = EntityRef.resolve("category", -1)
    end

    test "an existing service resolves to '<name> (<category>)', linking to its category's page",
         %{category: category, service: service} do
      assert {:link, "Catering (Venue)", path} = EntityRef.resolve("service", service.id)
      assert path == "/categories/#{category.id}"
    end

    test "a deleted service degrades to text", %{scope: scope, service: service} do
      {:ok, _} = Categories.delete_service(scope, service)

      assert {:text, _label} = EntityRef.resolve("service", service.id)
    end

    test "a merged-away service also degrades to text", %{
      scope: scope,
      category: category,
      service: service
    } do
      {:ok, other} = Categories.create_service(scope, category, %{"name" => "Catering extra"})
      {:ok, _merged} = Categories.merge_services(scope, service, other)

      assert {:text, _label} = EntityRef.resolve("service", service.id)
    end
  end

  describe "WeddingPlanner.Valuation.Snapshot integration (CST-01, CST-02)" do
    test "categories load in CST-01 manual sort order", %{scope: scope} do
      {:ok, a} = Categories.create_category(scope, %{"name" => "A"})
      {:ok, b} = Categories.create_category(scope, %{"name" => "B"})
      :ok = Categories.move_category(scope, b, :up)

      snapshot = Snapshot.load(Repo)
      assert Enum.map(snapshot.categories, & &1.id) == [b.id, a.id]
    end

    test "services load per category, each in its own manual sort order", %{scope: scope} do
      {:ok, cat1} = Categories.create_category(scope, %{"name" => "Venue"})
      {:ok, cat2} = Categories.create_category(scope, %{"name" => "Catering"})

      {:ok, s1} = Categories.create_service(scope, cat1, %{"name" => "Sound"})
      {:ok, s2} = Categories.create_service(scope, cat1, %{"name" => "Lighting"})
      {:ok, s3} = Categories.create_service(scope, cat2, %{"name" => "Buffet"})

      :ok = Categories.move_service(scope, s2, :up)

      snapshot = Snapshot.load(Repo)
      assert Enum.map(snapshot.services, & &1.id) == [s2.id, s1.id, s3.id]
    end
  end

  defp insert_user!(display_name) do
    %User{} |> User.changeset(%{display_name: display_name}) |> Repo.insert!()
  end
end
