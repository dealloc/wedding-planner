defmodule WeddingPlanner.Release do
  @moduledoc """
  Release tasks invoked from outside the application (there is no Mix and no source
  checkout inside a release, so `mix ecto.migrate` isn't available there).

  Invoked as `bin/wedding_planner eval "WeddingPlanner.Release.migrate()"`. The
  `rel/overlays/bin/migrate` script wraps that call, and `fly.toml` wires it up as Fly's
  `release_command`, so it runs once before each deploy's new machine takes traffic.

  NFR-03 / AUTH-09: this module is also where the operator recovery command lives once
  task 19 adds it — a command that generates an enrollment link for an existing user who
  has lost every device, run the same way (`bin/wedding_planner eval "WeddingPlanner.Release...`).
  The release plumbing for that (this module, the overlay script pattern, `fly.toml`) is
  created now so task 19 only has to add a function and a script, not a deployment story.
  """

  @app :wedding_planner

  def migrate do
    load_app()
    ensure_uploads_dir!()

    for repo <- repos() do
      # pool_size: 1 — this runs once, sequentially, against SQLite; a larger pool only
      # produces harmless but noisy "database is locked" retries while the WAL-mode
      # pragma is still being applied on a brand-new database file.
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true), pool_size: 1)
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end

  # NFR-04 / XC-23 — the uploads directory lives on the same persistent volume as the
  # database (see fly.toml's single mount). A freshly created Fly volume only guarantees
  # its own mount point exists, not this subdirectory underneath it, so it is created
  # here, once per deploy before migrations run, rather than assumed to be there.
  #
  # No module reads `:uploads_dir` yet (uploads are a later slice) so this is a no-op
  # until then, but the directory needs to exist on the volume from day one regardless.
  defp ensure_uploads_dir! do
    case Application.get_env(@app, :uploads_dir) do
      nil -> :ok
      dir -> File.mkdir_p!(dir)
    end
  end
end
