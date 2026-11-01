import { Link } from "@tanstack/react-router"
import { Button } from "@/components/ui/button"

const Forbidden = () => {
  return (
    <div
      className="flex min-h-[60vh] items-center justify-center flex-col p-4"
      data-testid="forbidden"
    >
      <div className="flex items-center z-10">
        <div className="flex flex-col ml-4 items-center justify-center p-4">
          <span className="text-6xl md:text-8xl font-bold leading-none mb-4">
            403
          </span>
          <span className="text-2xl font-bold mb-2">Access denied</span>
        </div>
      </div>

      <p className="text-lg text-muted-foreground mb-4 text-center z-10">
        Your role doesn't give you access to this page. Ask an administrator if
        you think you need it.
      </p>
      <div className="z-10">
        <Link to="/">
          <Button className="mt-4">Go Back</Button>
        </Link>
      </div>
    </div>
  )
}

export default Forbidden
