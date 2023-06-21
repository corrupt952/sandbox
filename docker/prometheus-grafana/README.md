# Monitoring RTX1300 using Prometheus and Grafana

## Usage

1. Configuring SNMP configuration on the RTX1300 (e.g. `snmp host any`)
1. Rewrite generator.yml as needed
1. If you rewrite generate.yml, execute `./generate-snmp-config.sh`
1. Change targets attribute in prometheus.yml to IP address of RTX1300
1. Run containers Prometheus, SNMP Exporter and Grafana
1. Access <http://127.0.0.1:3000> (user/pass ... `admin/admin`)
1. Create dashboard of RTX1300's metrics

## Examples

### Dashboard

```json
{
  "__inputs": [
    {
      "name": "DS_PROMETHEUS",
      "label": "Prometheus",
      "description": "",
      "type": "datasource",
      "pluginId": "prometheus",
      "pluginName": "Prometheus"
    }
  ],
  "__elements": {},
  "__requires": [
    {
      "type": "panel",
      "id": "gauge",
      "name": "Gauge",
      "version": ""
    },
    {
      "type": "grafana",
      "id": "grafana",
      "name": "Grafana",
      "version": "9.5.3"
    },
    {
      "type": "datasource",
      "id": "prometheus",
      "name": "Prometheus",
      "version": "1.0.0"
    },
    {
      "type": "panel",
      "id": "stat",
      "name": "Stat",
      "version": ""
    },
    {
      "type": "panel",
      "id": "timeseries",
      "name": "Time series",
      "version": ""
    }
  ],
  "annotations": {
    "list": [
      {
        "builtIn": 1,
        "datasource": {
          "type": "grafana",
          "uid": "-- Grafana --"
        },
        "enable": true,
        "hide": true,
        "iconColor": "rgba(0, 211, 255, 1)",
        "name": "Annotations & Alerts",
        "target": {
          "limit": 100,
          "matchAny": false,
          "tags": [],
          "type": "dashboard"
        },
        "type": "dashboard"
      }
    ]
  },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 0,
  "id": null,
  "links": [],
  "liveNow": false,
  "panels": [
    {
      "datasource": {
        "type": "prometheus",
        "uid": "${DS_PROMETHEUS}"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "fixedColor": "blue",
            "mode": "fixed"
          },
          "mappings": [],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              }
            ]
          },
          "unit": "dtdhms"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 6,
        "x": 0,
        "y": 0
      },
      "id": 18,
      "options": {
        "colorMode": "value",
        "graphMode": "none",
        "justifyMode": "auto",
        "orientation": "auto",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "textMode": "auto"
      },
      "pluginVersion": "9.5.3",
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "${DS_PROMETHEUS}"
          },
          "editorMode": "builder",
          "expr": "yrfUpTime / 100",
          "legendFormat": "__auto",
          "range": true,
          "refId": "A"
        }
      ],
      "title": "Uptime",
      "type": "stat"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "${DS_PROMETHEUS}"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "mappings": [],
          "max": 100,
          "min": 0,
          "thresholds": {
            "mode": "percentage",
            "steps": [
              {
                "color": "green",
                "value": null
              },
              {
                "color": "#EAB839",
                "value": 80
              },
              {
                "color": "red",
                "value": 90
              }
            ]
          },
          "unit": "percent"
        },
        "overrides": [
          {
            "matcher": {
              "id": "byName",
              "options": "{__name__=\"yrhMultiCpuUtil5sec\", instance=\"192.168.100.1\", job=\"snmp.rtx1300\", name=\"rtx1300\", vendor=\"yamaha\", yrhMultiCpuIndex=\"1\"}"
            },
            "properties": [
              {
                "id": "displayName",
                "value": "CPU 0"
              }
            ]
          },
          {
            "matcher": {
              "id": "byName",
              "options": "{__name__=\"yrhMultiCpuUtil5sec\", instance=\"192.168.100.1\", job=\"snmp.rtx1300\", name=\"rtx1300\", vendor=\"yamaha\", yrhMultiCpuIndex=\"2\"}"
            },
            "properties": [
              {
                "id": "displayName",
                "value": "CPU 1"
              }
            ]
          },
          {
            "matcher": {
              "id": "byName",
              "options": "{__name__=\"yrhMultiCpuUtil5sec\", instance=\"192.168.100.1\", job=\"snmp.rtx1300\", name=\"rtx1300\", vendor=\"yamaha\", yrhMultiCpuIndex=\"3\"}"
            },
            "properties": [
              {
                "id": "displayName",
                "value": "CPU 2"
              }
            ]
          },
          {
            "matcher": {
              "id": "byName",
              "options": "{__name__=\"yrhMultiCpuUtil5sec\", instance=\"192.168.100.1\", job=\"snmp.rtx1300\", name=\"rtx1300\", vendor=\"yamaha\", yrhMultiCpuIndex=\"4\"}"
            },
            "properties": [
              {
                "id": "displayName",
                "value": "CPU 4"
              }
            ]
          }
        ]
      },
      "gridPos": {
        "h": 8,
        "w": 18,
        "x": 6,
        "y": 0
      },
      "id": 8,
      "options": {
        "orientation": "auto",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "showThresholdLabels": false,
        "showThresholdMarkers": true
      },
      "pluginVersion": "9.5.3",
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "${DS_PROMETHEUS}"
          },
          "editorMode": "builder",
          "expr": "yrhMultiCpuUtil5sec",
          "legendFormat": "__auto",
          "range": true,
          "refId": "A"
        }
      ],
      "title": "CPU Utlization",
      "type": "gauge"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "${DS_PROMETHEUS}"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "axisCenteredZero": false,
            "axisColorMode": "text",
            "axisLabel": "",
            "axisPlacement": "auto",
            "barAlignment": 0,
            "drawStyle": "line",
            "fillOpacity": 30,
            "gradientMode": "none",
            "hideFrom": {
              "legend": false,
              "tooltip": false,
              "viz": false
            },
            "lineInterpolation": "smooth",
            "lineWidth": 1,
            "pointSize": 5,
            "scaleDistribution": {
              "type": "linear"
            },
            "showPoints": "auto",
            "spanNulls": false,
            "stacking": {
              "group": "A",
              "mode": "none"
            },
            "thresholdsStyle": {
              "mode": "off"
            }
          },
          "mappings": [],
          "max": 100,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              }
            ]
          },
          "unit": "percent"
        },
        "overrides": [
          {
            "matcher": {
              "id": "byName",
              "options": "{__name__=\"yrhMultiCpuUtil5sec\", instance=\"192.168.100.1\", job=\"snmp.rtx1300\", name=\"rtx1300\", vendor=\"yamaha\", yrhMultiCpuIndex=\"1\"}"
            },
            "properties": [
              {
                "id": "displayName",
                "value": "CPU 0"
              }
            ]
          },
          {
            "matcher": {
              "id": "byName",
              "options": "{__name__=\"yrhMultiCpuUtil5sec\", instance=\"192.168.100.1\", job=\"snmp.rtx1300\", name=\"rtx1300\", vendor=\"yamaha\", yrhMultiCpuIndex=\"2\"}"
            },
            "properties": [
              {
                "id": "displayName",
                "value": "CPU 1"
              }
            ]
          },
          {
            "matcher": {
              "id": "byName",
              "options": "{__name__=\"yrhMultiCpuUtil5sec\", instance=\"192.168.100.1\", job=\"snmp.rtx1300\", name=\"rtx1300\", vendor=\"yamaha\", yrhMultiCpuIndex=\"3\"}"
            },
            "properties": [
              {
                "id": "displayName",
                "value": "CPU 2"
              }
            ]
          },
          {
            "matcher": {
              "id": "byName",
              "options": "{__name__=\"yrhMultiCpuUtil5sec\", instance=\"192.168.100.1\", job=\"snmp.rtx1300\", name=\"rtx1300\", vendor=\"yamaha\", yrhMultiCpuIndex=\"4\"}"
            },
            "properties": [
              {
                "id": "displayName",
                "value": "CPU 3"
              }
            ]
          }
        ]
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 8
      },
      "id": 11,
      "options": {
        "legend": {
          "calcs": [
            "min",
            "max",
            "last"
          ],
          "displayMode": "table",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "single",
          "sort": "none"
        }
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "${DS_PROMETHEUS}"
          },
          "editorMode": "builder",
          "expr": "yrhMultiCpuUtil5sec",
          "legendFormat": "__auto",
          "range": true,
          "refId": "A"
        }
      ],
      "title": "CPU Utlization",
      "type": "timeseries"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "${DS_PROMETHEUS}"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "axisCenteredZero": false,
            "axisColorMode": "text",
            "axisLabel": "",
            "axisPlacement": "auto",
            "barAlignment": 0,
            "drawStyle": "line",
            "fillOpacity": 30,
            "gradientMode": "none",
            "hideFrom": {
              "legend": false,
              "tooltip": false,
              "viz": false
            },
            "lineInterpolation": "smooth",
            "lineWidth": 1,
            "pointSize": 5,
            "scaleDistribution": {
              "type": "linear"
            },
            "showPoints": "auto",
            "spanNulls": false,
            "stacking": {
              "group": "A",
              "mode": "none"
            },
            "thresholdsStyle": {
              "mode": "off"
            }
          },
          "mappings": [],
          "max": 100,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              }
            ]
          },
          "unit": "percent"
        },
        "overrides": [
          {
            "matcher": {
              "id": "byName",
              "options": "{__name__=\"yrhMemoryUtil\", instance=\"192.168.100.1\", job=\"snmp.rtx1300\", name=\"rtx1300\", vendor=\"yamaha\"}"
            },
            "properties": [
              {
                "id": "displayName",
                "value": "RTX 1300"
              }
            ]
          }
        ]
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 8
      },
      "id": 10,
      "options": {
        "legend": {
          "calcs": [
            "min",
            "max",
            "last"
          ],
          "displayMode": "table",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "single",
          "sort": "none"
        }
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "${DS_PROMETHEUS}"
          },
          "editorMode": "builder",
          "expr": "yrhMemoryUtil",
          "legendFormat": "__auto",
          "range": true,
          "refId": "A"
        }
      ],
      "title": "Memory Utlization",
      "type": "timeseries"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "${DS_PROMETHEUS}"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "axisCenteredZero": false,
            "axisColorMode": "text",
            "axisLabel": "",
            "axisPlacement": "auto",
            "barAlignment": 0,
            "drawStyle": "line",
            "fillOpacity": 30,
            "gradientMode": "none",
            "hideFrom": {
              "legend": false,
              "tooltip": false,
              "viz": false
            },
            "lineInterpolation": "smooth",
            "lineWidth": 1,
            "pointSize": 5,
            "scaleDistribution": {
              "type": "linear"
            },
            "showPoints": "auto",
            "spanNulls": false,
            "stacking": {
              "group": "A",
              "mode": "none"
            },
            "thresholdsStyle": {
              "mode": "off"
            }
          },
          "mappings": [],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              },
              {
                "color": "red",
                "value": 80
              }
            ]
          },
          "unit": "Bps"
        },
        "overrides": [
          {
            "matcher": {
              "id": "byFrameRefID",
              "options": "A"
            },
            "properties": [
              {
                "id": "displayName",
                "value": "In"
              }
            ]
          },
          {
            "matcher": {
              "id": "byFrameRefID",
              "options": "B"
            },
            "properties": [
              {
                "id": "displayName",
                "value": "Out"
              }
            ]
          }
        ]
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 16
      },
      "id": 19,
      "options": {
        "legend": {
          "calcs": [
            "min",
            "max",
            "last"
          ],
          "displayMode": "table",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "single",
          "sort": "none"
        }
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "${DS_PROMETHEUS}"
          },
          "editorMode": "builder",
          "exemplar": false,
          "expr": "delta(ifInOctets{ifIndex=\"2\"}[$__interval])",
          "format": "time_series",
          "instant": false,
          "interval": "",
          "legendFormat": "__auto",
          "range": true,
          "refId": "A"
        },
        {
          "datasource": {
            "type": "prometheus",
            "uid": "${DS_PROMETHEUS}"
          },
          "editorMode": "builder",
          "expr": "delta(ifOutOctets{ifIndex=\"2\"}[$__interval])",
          "hide": false,
          "legendFormat": "__auto",
          "range": true,
          "refId": "B"
        }
      ],
      "title": "Traffic (WAN)",
      "type": "timeseries"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "${DS_PROMETHEUS}"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "axisCenteredZero": false,
            "axisColorMode": "text",
            "axisLabel": "",
            "axisPlacement": "auto",
            "barAlignment": 0,
            "drawStyle": "line",
            "fillOpacity": 30,
            "gradientMode": "none",
            "hideFrom": {
              "legend": false,
              "tooltip": false,
              "viz": false
            },
            "lineInterpolation": "smooth",
            "lineWidth": 1,
            "pointSize": 5,
            "scaleDistribution": {
              "type": "linear"
            },
            "showPoints": "auto",
            "spanNulls": false,
            "stacking": {
              "group": "A",
              "mode": "none"
            },
            "thresholdsStyle": {
              "mode": "off"
            }
          },
          "mappings": [],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              }
            ]
          },
          "unit": "Bps"
        },
        "overrides": [
          {
            "matcher": {
              "id": "byFrameRefID",
              "options": "A"
            },
            "properties": [
              {
                "id": "displayName",
                "value": "In"
              }
            ]
          },
          {
            "matcher": {
              "id": "byFrameRefID",
              "options": "B"
            },
            "properties": [
              {
                "id": "displayName",
                "value": "Out"
              }
            ]
          }
        ]
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 16
      },
      "id": 20,
      "options": {
        "legend": {
          "calcs": [
            "min",
            "max",
            "last"
          ],
          "displayMode": "table",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "single",
          "sort": "none"
        }
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "${DS_PROMETHEUS}"
          },
          "editorMode": "builder",
          "exemplar": false,
          "expr": "delta(ifInOctets{ifIndex=\"1\"}[$__interval])",
          "format": "time_series",
          "instant": false,
          "interval": "",
          "legendFormat": "__auto",
          "range": true,
          "refId": "A"
        },
        {
          "datasource": {
            "type": "prometheus",
            "uid": "${DS_PROMETHEUS}"
          },
          "editorMode": "builder",
          "expr": "delta(ifOutOctets{ifIndex=\"1\"}[$__interval])",
          "hide": false,
          "legendFormat": "__auto",
          "range": true,
          "refId": "B"
        }
      ],
      "title": "Traffic (LAN)",
      "type": "timeseries"
    }
  ],
  "refresh": "5s",
  "schemaVersion": 38,
  "style": "dark",
  "tags": [],
  "templating": {
    "list": []
  },
  "time": {
    "from": "now-5m",
    "to": "now"
  },
  "timepicker": {},
  "timezone": "Asia/Tokyo",
  "title": "RTX1300",
  "uid": "eEntLKSVz2",
  "version": 1,
  "weekStart": "sunday"
}
```
