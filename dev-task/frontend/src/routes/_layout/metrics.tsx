import { useSuspenseQuery } from "@tanstack/react-query"
import { createFileRoute } from "@tanstack/react-router"
import { Suspense } from "react"

import { MetricsService } from "@/client"
import Forbidden from "@/components/Common/Forbidden"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import useAuth from "@/hooks/useAuth"

function getMetricsQueryOptions() {
  return {
    queryFn: async () => (await MetricsService.readMetrics()).data,
    queryKey: ["metrics"],
  }
}

export const Route = createFileRoute("/_layout/metrics")({
  component: Metrics,
  head: () => ({
    meta: [
      {
        title: "Metrics - FastAPI Template",
      },
    ],
  }),
})

function MetricCard({ title, value }: { title: string; value: number }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-sm font-medium text-muted-foreground">
          {title}
        </CardTitle>
      </CardHeader>
      <CardContent>
        <span className="text-3xl font-bold">{value}</span>
      </CardContent>
    </Card>
  )
}

function MetricsContent() {
  const { data: metrics } = useSuspenseQuery(getMetricsQueryOptions())

  return (
    <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
      <MetricCard title="Total users" value={metrics.total_users} />
      <MetricCard title="Active users" value={metrics.active_users} />
      <MetricCard title="Total items" value={metrics.total_items} />
    </div>
  )
}

const pendingMetrics = (
  <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
    <Skeleton className="h-28" />
    <Skeleton className="h-28" />
    <Skeleton className="h-28" />
  </div>
)

function Metrics() {
  const { can } = useAuth()

  if (!can("metrics:read")) {
    return <Forbidden />
  }

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Metrics</h1>
        <p className="text-muted-foreground">Usage across this instance</p>
      </div>
      <Suspense fallback={pendingMetrics}>
        <MetricsContent />
      </Suspense>
    </div>
  )
}
