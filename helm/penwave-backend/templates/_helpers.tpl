{{- define "penwave-backend.labels" -}}
app.kubernetes.io/name: penwave-backend
app.kubernetes.io/part-of: penwave
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
