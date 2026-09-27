{{/*
Name helpers
*/}}
{{- define "cap.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cap.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "cap.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "cap.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.global.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Per-component selector labels. Usage: include "cap.selectorLabels" (dict "root" . "component" "web")
*/}}
{{- define "cap.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cap.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
Image reference builder.
Usage: include "cap.image" (dict "root" . "img" .Values.images.web)
- If global.imageRegistry is set, it overrides the per-image registry (private-registry flip).
- Digest is preferred over tag when present.
*/}}
{{- define "cap.image" -}}
{{- $g := .root.Values.global.imageRegistry -}}
{{- $reg := .img.registry -}}
{{- if $g -}}{{- $reg = $g -}}{{- end -}}
{{- $ref := .img.repository -}}
{{- if $reg -}}{{- $ref = printf "%s/%s" $reg .img.repository -}}{{- end -}}
{{- if .img.digest -}}
{{- printf "%s@%s" $ref .img.digest -}}
{{- else -}}
{{- printf "%s:%s" $ref (.img.tag | toString) -}}
{{- end -}}
{{- end -}}

{{/*
imagePullSecrets block
*/}}
{{- define "cap.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range . }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Name of the Secret holding app secrets (generated or external).
*/}}
{{- define "cap.secretName" -}}
{{- if .Values.secrets.existingSecret -}}
{{- .Values.secrets.existingSecret -}}
{{- else -}}
{{- printf "%s-secrets" (include "cap.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Proxy + CA environment. Injected into web and media-server so egress traverses the
customer's forward proxy and trusts its intercepting CA.
*/}}
{{- define "cap.proxyEnv" -}}
{{- if .Values.egress.proxy.enabled }}
- name: HTTP_PROXY
  value: {{ .Values.egress.proxy.http | quote }}
- name: HTTPS_PROXY
  value: {{ .Values.egress.proxy.https | quote }}
- name: http_proxy
  value: {{ .Values.egress.proxy.http | quote }}
- name: https_proxy
  value: {{ .Values.egress.proxy.https | quote }}
- name: NO_PROXY
  value: {{ .Values.egress.proxy.noProxy | quote }}
- name: no_proxy
  value: {{ .Values.egress.proxy.noProxy | quote }}
{{- end }}
{{- if .Values.egress.ca.enabled }}
- name: NODE_EXTRA_CA_CERTS
  value: /etc/ssl/halden/{{ .Values.egress.ca.key }}
{{- end }}
{{- end -}}

{{/*
CA volume + mount snippets (used when egress.ca.enabled)
*/}}
{{- define "cap.caVolume" -}}
{{- if .Values.egress.ca.enabled }}
- name: halden-proxy-ca
  configMap:
    name: {{ .Values.egress.ca.configMapName }}
{{- end }}
{{- end -}}

{{- define "cap.caVolumeMount" -}}
{{- if .Values.egress.ca.enabled }}
- name: halden-proxy-ca
  mountPath: /etc/ssl/halden
  readOnly: true
{{- end }}
{{- end -}}
