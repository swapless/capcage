variable "namespace" {
  type    = string
  default = "cap"
}

variable "chart_path" {
  type        = string
  description = "Path to the Cap Helm chart"
}

variable "values_file" {
  type        = string
  description = "Path to the values profile for this target"
}

variable "image_registry" {
  type        = string
  description = "Private registry prefix; empty uses per-image defaults"
  default     = ""
}
