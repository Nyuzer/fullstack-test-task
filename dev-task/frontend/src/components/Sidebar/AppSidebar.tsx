import { BarChart3, Briefcase, Home, Users } from "lucide-react"

import { SidebarAppearance } from "@/components/Common/Appearance"
import { Logo } from "@/components/Common/Logo"
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarHeader,
} from "@/components/ui/sidebar"
import type { Permission } from "@/hooks/useAuth"
import useAuth from "@/hooks/useAuth"
import { type Item, Main } from "./Main"
import { User } from "./User"

/** `requires` undefined means the entry is visible to every signed-in user. */
type NavItem = Item & { requires?: Permission }

const navItems: NavItem[] = [
  { icon: Home, title: "Dashboard", path: "/" },
  { icon: Briefcase, title: "Items", path: "/items" },
  { icon: BarChart3, title: "Metrics", path: "/metrics", requires: "metrics:read" },
  { icon: Users, title: "Admin", path: "/admin", requires: "users:read" },
]

export function AppSidebar() {
  const { user: currentUser, can } = useAuth()

  const items = navItems.filter((item) => !item.requires || can(item.requires))

  return (
    <Sidebar collapsible="icon">
      <SidebarHeader className="px-4 py-6 group-data-[collapsible=icon]:px-0 group-data-[collapsible=icon]:items-center">
        <Logo variant="responsive" />
      </SidebarHeader>
      <SidebarContent>
        <Main items={items} />
      </SidebarContent>
      <SidebarFooter>
        <SidebarAppearance />
        <User user={currentUser} />
      </SidebarFooter>
    </Sidebar>
  )
}

export default AppSidebar
