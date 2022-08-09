/**
 * Copyright 2021 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

data "google_project" "project" {
  project_id = var.project_id
}

locals {
  sabuild   = "${data.google_project.project.number}@cloudbuild.gserviceaccount.com"
  sacompute = "${data.google_project.project.number}-compute@developer.gserviceaccount.com"
  api_image = "us-central1-docker.pkg.dev/sic-container-repo/todo-app/api"
}






module "project-services" {
  source                      = "terraform-google-modules/project-factory/google//modules/project_services"
  version                     = "13.0.0"
  disable_services_on_destroy = false

  project_id  = var.project_id
  enable_apis = var.enable_apis

  activate_apis = [
    "compute.googleapis.com",
    "cloudapis.googleapis.com",
    "vpcaccess.googleapis.com",
    "servicenetworking.googleapis.com",
    "cloudbuild.googleapis.com",
    "sql-component.googleapis.com",
    "sqladmin.googleapis.com",
    "storage.googleapis.com",
    "secretmanager.googleapis.com",
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "redis.googleapis.com",
    "workflows.googleapis.com"
  ]
}







# TODO: See if this can be modularized
# Handle Permissions
variable "build_roles_list" {
  description = "The list of roles that build needs for"
  type        = list(string)
  default = [
    "roles/run.developer",
    "roles/vpaccess.user",
    "roles/iam.serviceAccountUser",
    "roles/run.admin",
    "roles/secretmanager.secretAccessor",
    "roles/artifactregistry.admin",
  ]
}

resource "google_project_iam_member" "allbuild" {
  for_each   = toset(var.build_roles_list)
  project    = data.google_project.project.number
  role       = each.key
  member     = "serviceAccount:${local.sabuild}"
  depends_on = [module.project-services]
}

resource "google_project_iam_member" "secretmanager_secretAccessor" {
  project    = var.project_id
  role       = "roles/secretmanager.secretAccessor"
  member     = "serviceAccount:${local.sacompute}"
  depends_on = [module.project-services]
}






resource "google_compute_network" "main" {
  provider                = google-beta
  name                    = "${var.deployment_name}-network"
  auto_create_subnetworks = false
  project                 = var.project_id
  depends_on = [
    module.project-services
  ]
}

# # Handle Networking details
resource "google_compute_global_address" "main" {
  name          = "google-managed-services-vpn-connector"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.main.id
  project       = var.project_id
  depends_on    = [module.project-services]
}

resource "google_service_networking_connection" "main" {
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.main.name]
}

resource "google_vpc_access_connector" "main" {
  provider       = google-beta
  project        = var.project_id
  name           = "vpc-connector"
  ip_cidr_range  = "10.8.0.0/28"
  network        = google_compute_network.main.id
  region         = var.region
  max_throughput = 300
  depends_on     = [google_compute_global_address.main, module.project-services]
}

resource "random_id" "id" {
  byte_length = 2
}

# Handle Database
resource "google_sql_database_instance" "main" {
  name             = "${var.deployment_name}-db-${random_id.id.hex}-2"
  database_version = "MYSQL_5_7"
  region           = var.region
  project          = var.project_id
  settings {
    tier                  = "db-g1-small"
    disk_autoresize       = true
    disk_autoresize_limit = 0
    disk_size             = 10
    disk_type             = "PD_SSD"
    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.main.id
    }
    location_preference {
      zone = var.zone
    }
  }
  deletion_protection = true
  depends_on = [
    module.project-services,
    google_service_networking_connection.main
  ]


}

resource "google_sql_database" "database" {
  project  = var.project_id
  name     = "todo"
  instance = google_sql_database_instance.main.name
}




resource "google_sql_user" "main" {
  project  = var.project_id
  name     = "todo_user"
  password = "todo_pass"
  instance = google_sql_database_instance.main.name
}



# Handle redis instance
resource "google_redis_instance" "main" {
  authorized_network      = google_compute_network.main.id
  connect_mode            = "DIRECT_PEERING"
  location_id             = var.zone
  memory_size_gb          = 1
  name                    = "${var.deployment_name}-cache"
  project                 = var.project_id
  redis_version           = "REDIS_6_X"
  region                  = var.region
  reserved_ip_range       = "10.137.125.88/29"
  tier                    = "BASIC"
  transit_encryption_mode = "DISABLED"
  depends_on              = [module.project-services]
}

# # Handle artifact registry
# resource "google_artifact_registry_repository" "todo_app" {
#   provider      = google-beta
#   format        = "DOCKER"
#   location      = var.region
#   project       = var.project_id
#   repository_id = "${var.deployment_name}-app"
#   depends_on    = [module.project-services]
# }

# # Handle secrets
resource "google_secret_manager_secret" "redishost" {
  project = data.google_project.project.number
  replication {
    automatic = true
  }
  secret_id  = "redishost"
  depends_on = [module.project-services]
}

resource "google_secret_manager_secret_version" "redishost" {
  enabled     = true
  secret      = "projects/${data.google_project.project.number}/secrets/redishost"
  secret_data = google_redis_instance.main.host
  depends_on  = [module.project-services, google_redis_instance.main, google_secret_manager_secret.redishost]
}

resource "google_secret_manager_secret" "sqlhost" {
  project = data.google_project.project.number
  replication {
    automatic = true
  }
  secret_id  = "sqlhost"
  depends_on = [module.project-services]
}

resource "google_secret_manager_secret_version" "sqlhost" {
  enabled     = true
  secret      = "projects/${data.google_project.project.number}/secrets/sqlhost"
  secret_data = google_sql_database_instance.main.private_ip_address
  depends_on  = [module.project-services, google_sql_database_instance.main, google_secret_manager_secret.sqlhost]
}

# resource "null_resource" "cloudbuild_api" {
#   provisioner "local-exec" {
#     working_dir = "${path.module}/code/middleware"
#     command     = "gcloud builds submit . --substitutions=_REGION=${var.region},_BASENAME=${var.deployment_name}"
#   }

#   depends_on = [
#     google_artifact_registry_repository.todo_app,
#     google_secret_manager_secret_version.redishost,
#     google_secret_manager_secret_version.sqlhost,
#     module.project-services
#   ]
# }

resource "google_cloud_run_service" "api" {
  name     = "${var.deployment_name}-api"
  provider = google-beta
  location = var.region
  project  = var.project_id

  template {
    spec {
      containers {
        image = local.api_image
        env {
          name = "REDISHOST"
          value_from {
            secret_key_ref {
              name = google_secret_manager_secret.redishost.secret_id
              key  = "latest"
            }
          }
        }
        env {
          name = "todo_host"
          value_from {
            secret_key_ref {
              name = google_secret_manager_secret.sqlhost.secret_id
              key  = "latest"
            }
          }
        }
        env {
          name  = "todo_user"
          value = "todo_user"
        }
        env {
          name  = "todo_pass"
          value = "todo_pass"
        }
        env {
          name  = "todo_name"
          value = "todo"
        }

        env {
          name  = "REDISPORT"
          value = "6379"
        }

      }
    }

    metadata {
      annotations = {
        "autoscaling.knative.dev/maxScale"        = "1000"
        "run.googleapis.com/cloudsql-instances"   = google_sql_database_instance.main.connection_name
        "run.googleapis.com/client-name"          = "terraform"
        "run.googleapis.com/vpc-access-egress"    = "all"
        "run.googleapis.com/vpc-access-connector" = google_vpc_access_connector.main.id
      }
    }
  }
  autogenerate_revision_name = true
  depends_on = [
    google_project_iam_member.secretmanager_secretAccessor
  ]
}


data "google_iam_policy" "noauth" {
  binding {
    role = "roles/run.invoker"
    members = [
      "allUsers",
    ]
  }
}


resource "google_cloud_run_service_iam_policy" "noauth_api" {
  location    = google_cloud_run_service.api.location
  project     = google_cloud_run_service.api.project
  service     = google_cloud_run_service.api.name
  policy_data = data.google_iam_policy.noauth.policy_data
}

# resource "null_resource" "cloudbuild_fe" {
#   provisioner "local-exec" {
#     working_dir = "${path.module}/code/frontend"
#     command     = "gcloud builds submit . --substitutions=_REGION=${var.region},_BASENAME=${var.deployment_name}"
#   }

#   depends_on = [
#     google_artifact_registry_repository.todo_app,
#     google_cloud_run_service.api
#   ]
# }

# resource "google_cloud_run_service" "fe" {
#   name     = "${var.deployment_name}-fe"
#   location = var.region
#   project  = var.project_id

#   template {
#     spec {
#       containers {
#         image = "${var.region}-docker.pkg.dev/${var.project_id}/${var.deployment_name}-app/fe"
#         ports {
#           container_port = 80
#         }
#       }
#     }
#   }
#   depends_on = [null_resource.cloudbuild_fe]
# }

# resource "google_cloud_run_service_iam_policy" "noauth_fe" {
#   location    = google_cloud_run_service.fe.location
#   project     = google_cloud_run_service.fe.project
#   service     = google_cloud_run_service.fe.name
#   policy_data = data.google_iam_policy.noauth.policy_data
# }