{{/* ------------------------------------------------------------------ */}}
{{/* 名称                                                               */}}
{{/* ------------------------------------------------------------------ */}}
{{- define "uk.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "uk.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "uk.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "uk.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* ------------------------------------------------------------------ */}}
{{/* 标签                                                               */}}
{{/* ------------------------------------------------------------------ */}}
{{/* 仅用于对象 metadata，可自由增删，不影响已运行的 Pod */}}
{{- define "uk.labels" -}}
app: {{ .Values.appLabel }}
app.kubernetes.io/name: {{ include "uk.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ include "uk.chart" . }}
{{- end -}}

{{/* 用于 selector 与 Pod template：必须与线上已有 Deployment 完全一致 */}}
{{- define "uk.selectorLabels" -}}
app: {{ .Values.appLabel }}
{{- end -}}

{{/* ------------------------------------------------------------------ */}}
{{/* 其他                                                               */}}
{{/* ------------------------------------------------------------------ */}}
{{- define "uk.pvcName" -}}
{{- .Values.persistence.existingClaim | default .Values.persistence.name -}}
{{- end -}}

{{- define "uk.backupName" -}}
{{- printf "%s-backup" (include "uk.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
