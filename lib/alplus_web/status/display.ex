defmodule AlplusWeb.Status.Display do
  @moduledoc """
  Labels, tones, and icons for status-page incident stages and maintenance
  windows.

  The public status page and the authenticated status workspace show the same
  stage and maintenance vocabulary, so both read it here.
  """

  @spec incident_stage_label(String.t()) :: String.t()
  def incident_stage_label("investigating"), do: "Investigating"
  def incident_stage_label("identified"), do: "Identified"
  def incident_stage_label("monitoring"), do: "Monitoring"
  def incident_stage_label("resolved"), do: "Resolved"
  def incident_stage_label(stage), do: stage

  @spec stage_tone(String.t()) :: String.t()
  def stage_tone("investigating"), do: "error"
  def stage_tone("identified"), do: "warning"
  def stage_tone("monitoring"), do: "info"
  def stage_tone("resolved"), do: "success"
  def stage_tone(_stage), do: "neutral"

  @spec stage_icon(String.t()) :: String.t()
  def stage_icon("investigating"), do: "hero-magnifying-glass"
  def stage_icon("identified"), do: "hero-exclamation-triangle"
  def stage_icon("monitoring"), do: "hero-eye"
  def stage_icon("resolved"), do: "hero-check-circle"
  def stage_icon(_stage), do: "hero-minus-circle"

  @spec maintenance_status_label(String.t()) :: String.t()
  def maintenance_status_label("active"), do: "In progress"
  def maintenance_status_label("scheduled"), do: "Scheduled"
  def maintenance_status_label("completed"), do: "Completed"
  def maintenance_status_label("cancelled"), do: "Cancelled"
  def maintenance_status_label(status), do: status

  @spec maintenance_status_tone(String.t()) :: String.t()
  def maintenance_status_tone("active"), do: "info"
  def maintenance_status_tone("scheduled"), do: "info"
  def maintenance_status_tone("completed"), do: "success"
  def maintenance_status_tone("cancelled"), do: "neutral"
  def maintenance_status_tone(_status), do: "neutral"

  @spec maintenance_status_icon(String.t()) :: String.t()
  def maintenance_status_icon("active"), do: "hero-wrench-screwdriver"
  def maintenance_status_icon("scheduled"), do: "hero-information-circle"
  def maintenance_status_icon("completed"), do: "hero-check-circle"
  def maintenance_status_icon("cancelled"), do: "hero-x-circle"
  def maintenance_status_icon(_status), do: "hero-minus-circle"
end
