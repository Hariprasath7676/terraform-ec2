variable "aws_region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "instance_name" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "security_group_name" {
  type = string
}

variable "iam_instance_profile" {
  type = string
}

variable "root_volume_size" {
  type = number
}

variable "data_volume_size" {
  type = number
}

variable "key_name" {
  type = string
}

variable "s3_bucket" {
  type = string
}

variable "s3_key_path" {
  type = string
}

variable "application_type" {
  type = string
}

variable "app_username" {
  type        = string
  default     = ""
  description = "Application Username"
}

variable "app_password" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Application Password"
}

variable "app_database" {
  type        = string
  default     = ""
  description = "Application Database"
}
