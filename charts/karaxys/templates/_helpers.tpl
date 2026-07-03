{{/* Common name + labels */}}
{{- define "karaxys.name" -}}
{{- default "karaxys" .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "karaxys.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "karaxys.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "karaxys.labels" -}}
app.kubernetes.io/name: {{ include "karaxys.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/* Per-component selector labels: include "karaxys.selector" (dict "ctx" $ "component" "api-server") */}}
{{- define "karaxys.selector" -}}
app.kubernetes.io/name: {{ include "karaxys.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/* Fully-qualified image ref: include "karaxys.image" (dict "ctx" $ "svc" "api-server") */}}
{{- define "karaxys.image" -}}
{{- printf "%s/karaxys-%s:%s" .ctx.Values.image.registry .svc .ctx.Values.image.tag -}}
{{- end -}}

{{/* Fail the render if a required secret value is empty. */}}
{{- define "karaxys.requireSecret" -}}
{{- if not .val -}}
{{- fail (printf "secrets.%s is required — pass it with --set or a values file" .name) -}}
{{- end -}}
{{- .val -}}
{{- end -}}

{{/* envFrom the shared secret + config, used by every backend service. */}}
{{- define "karaxys.backendEnvFrom" -}}
- secretRef:
    name: {{ include "karaxys.fullname" . }}-secrets
- configMapRef:
    name: {{ include "karaxys.fullname" . }}-config
{{- end -}}
