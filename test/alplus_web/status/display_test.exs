defmodule AlplusWeb.Status.DisplayTest do
  use ExUnit.Case, async: true

  alias AlplusWeb.Status.Display

  test "incident_stage_label/1 maps every stage" do
    assert Display.incident_stage_label("investigating") == "Investigating"
    assert Display.incident_stage_label("identified") == "Identified"
    assert Display.incident_stage_label("monitoring") == "Monitoring"
    assert Display.incident_stage_label("resolved") == "Resolved"
    assert Display.incident_stage_label("other") == "other"
  end

  test "stage_tone/1 maps every stage" do
    assert Display.stage_tone("investigating") == "error"
    assert Display.stage_tone("identified") == "warning"
    assert Display.stage_tone("monitoring") == "info"
    assert Display.stage_tone("resolved") == "success"
    assert Display.stage_tone("other") == "neutral"
  end

  test "stage_icon/1 maps every stage" do
    assert Display.stage_icon("investigating") == "hero-magnifying-glass"
    assert Display.stage_icon("identified") == "hero-exclamation-triangle"
    assert Display.stage_icon("monitoring") == "hero-eye"
    assert Display.stage_icon("resolved") == "hero-check-circle"
    assert Display.stage_icon("other") == "hero-minus-circle"
  end

  test "maintenance_status_label/1 maps every status" do
    assert Display.maintenance_status_label("active") == "In progress"
    assert Display.maintenance_status_label("scheduled") == "Scheduled"
    assert Display.maintenance_status_label("completed") == "Completed"
    assert Display.maintenance_status_label("cancelled") == "Cancelled"
    assert Display.maintenance_status_label("other") == "other"
  end

  test "maintenance_status_tone/1 maps every status" do
    assert Display.maintenance_status_tone("active") == "info"
    assert Display.maintenance_status_tone("scheduled") == "info"
    assert Display.maintenance_status_tone("completed") == "success"
    assert Display.maintenance_status_tone("cancelled") == "neutral"
    assert Display.maintenance_status_tone("other") == "neutral"
  end

  test "maintenance_status_icon/1 maps every status" do
    assert Display.maintenance_status_icon("active") == "hero-wrench-screwdriver"
    assert Display.maintenance_status_icon("scheduled") == "hero-information-circle"
    assert Display.maintenance_status_icon("completed") == "hero-check-circle"
    assert Display.maintenance_status_icon("cancelled") == "hero-x-circle"
    assert Display.maintenance_status_icon("other") == "hero-minus-circle"
  end
end
