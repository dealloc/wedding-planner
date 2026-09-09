defmodule WeddingPlannerWeb.PageController do
  use WeddingPlannerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
