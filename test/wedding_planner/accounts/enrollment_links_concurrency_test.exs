defmodule WeddingPlanner.Accounts.EnrollmentLinksConcurrencyTest do
  @moduledoc """
  `AUTH-06`'s single-use guarantee (`WeddingPlanner.Accounts.EnrollmentLinks.claim/2`),
  proven against real, independent database connections rather than the SQL sandbox's
  single serialized connection — the sandbox would make "only one winner" trivially true
  no matter whether `claim/2` is actually atomic, since every query would funnel through
  one connection regardless. Mirrors `WeddingPlanner.Accounts.SetupConcurrencyTest`'s
  approach to the same class of race for `DR-22`; see that module's moduledoc for why
  this runs outside `DataCase` with the sandbox mode flipped to `:auto`.

  `WeddingPlannerWeb.Live.EnrollmentLive` only calls `claim/2` after a real WebAuthn
  ceremony has already succeeded, so this is the one place that actually decides which of
  two devices racing to redeem the same link "wins" — a full end-to-end race through two
  simulated ceremonies would exercise the same atomic `UPDATE` this test hits directly.
  """
  use ExUnit.Case, async: false

  alias WeddingPlanner.Accounts.EnrollmentLink
  alias WeddingPlanner.Accounts.EnrollmentLinks
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Repo

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    {:ok, issuer} = %User{} |> User.changeset(%{display_name: "Wannes"}) |> Repo.insert()
    {:ok, link} = EnrollmentLinks.create_device_link(issuer)

    on_exit(fn ->
      Repo.delete_all(EnrollmentLink)
      Repo.delete_all(User)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    %{link: link}
  end

  test "exactly one concurrent claim on the same link succeeds", %{link: link} do
    racers = 8
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    parent = self()

    tasks =
      for _ <- 1..racers do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> EnrollmentLinks.claim(link, now)
          end
        end)
      end

    for %Task{pid: pid} <- tasks, do: assert_receive({:ready, ^pid})
    for %Task{pid: pid} <- tasks, do: send(pid, :go)

    results = Task.await_many(tasks, 10_000)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == :error)) == racers - 1
    assert %EnrollmentLink{used_at: %DateTime{}} = Repo.get(EnrollmentLink, link.id)
  end
end
