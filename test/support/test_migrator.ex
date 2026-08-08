defmodule Defdo.Tasks.TestMigrator do
  @moduledoc """
  A stand-in for `Defdo.Tenant.Migrator` with three version modules and no
  fourth, so `MigratorChain.target_version/1` can be tested against a real
  module tree rather than a mock.
  """
end

defmodule Defdo.Tasks.TestMigrator.V01 do
  @moduledoc false
end

defmodule Defdo.Tasks.TestMigrator.V02 do
  @moduledoc false
end

defmodule Defdo.Tasks.TestMigrator.V03 do
  @moduledoc false
end
