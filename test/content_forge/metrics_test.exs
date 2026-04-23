defmodule ContentForge.MetricsTest do
  use ContentForge.DataCase, async: true

  alias ContentForge.Metrics
  alias ContentForge.Products

  defp create_product do
    {:ok, product} =
      Products.create_product(%{
        name: "Test Product",
        voice_profile: "professional"
      })

    product
  end

  describe "create_scoreboard_entry/1" do
    test "with valid attrs succeeds" do
      product = create_product()

      attrs = %{
        content_id: Ecto.UUID.generate(),
        product_id: product.id,
        platform: "youtube",
        measured_at: DateTime.utc_now()
      }

      assert {:ok, entry} = Metrics.create_scoreboard_entry(attrs)
      assert entry.product_id == product.id
      assert entry.platform == "youtube"
    end

    test "with missing required fields returns {:error, changeset}" do
      assert {:error, changeset} = Metrics.create_scoreboard_entry(%{})
      errors = errors_on(changeset)
      assert Map.has_key?(errors, :content_id)
      assert Map.has_key?(errors, :product_id)
      assert Map.has_key?(errors, :platform)
    end
  end

  describe "update_model_calibration/2" do
    test "with valid data succeeds and updates avg_score_delta" do
      product = create_product()

      {:ok, entry} =
        Metrics.create_scoreboard_entry(%{
          content_id: Ecto.UUID.generate(),
          product_id: product.id,
          platform: "twitter",
          composite_ai_score: 5.0,
          measured_at: DateTime.utc_now()
        })

      per_model_scores = %{"claude" => 6.0}

      assert :ok = Metrics.update_model_calibration(entry, per_model_scores)

      calibration = Metrics.get_model_calibration(product.id, "claude", "twitter")
      assert calibration != nil
      assert calibration.sample_count == 1
      assert calibration.avg_score_delta == 1.0
    end

    test "on a non-existent record creates it" do
      product = create_product()

      {:ok, entry} =
        Metrics.create_scoreboard_entry(%{
          content_id: Ecto.UUID.generate(),
          product_id: product.id,
          platform: "linkedin",
          composite_ai_score: 4.0,
          measured_at: DateTime.utc_now()
        })

      per_model_scores = %{"gemini" => 3.0}

      assert :ok = Metrics.update_model_calibration(entry, per_model_scores)

      calibration = Metrics.get_model_calibration(product.id, "gemini", "linkedin")
      assert calibration != nil
      assert calibration.model_name == "gemini"
      assert calibration.sample_count == 1
    end
  end
end
