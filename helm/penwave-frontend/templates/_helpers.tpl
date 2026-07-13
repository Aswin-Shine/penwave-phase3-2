{{- define "penwave-frontend.labels" -}}
app.kubernetes.io/name: penwave-frontend
app.kubernetes.io/part-of: penwave
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
