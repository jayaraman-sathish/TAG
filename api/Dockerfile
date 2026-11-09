# syntax=docker/dockerfile:1
# =====================================================================
#  TagTrail API
#
#  Two stages: build with the SDK, run on the much smaller ASP.NET
#  runtime. The published image carries no compiler and no source.
#
#  The SDK image is pinned to 8.0 to match <TargetFramework>net8.0 in the
#  csproj. That is deliberate: it makes the build independent of whichever
#  .NET is installed on the machine running docker, which is the whole
#  reason for putting it in a container.
# =====================================================================

FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

# Restore on its own layer, keyed only on the project file. Docker then
# re-uses the restored packages on every later build where only the C#
# changed, which is almost every build.
COPY TagTrail.Api.csproj ./
RUN dotnet restore

COPY . ./
RUN dotnet publish -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime
WORKDIR /app
COPY --from=build /app ./

# The aspnet image listens on 8080 as a non-root user. compose maps this to
# 5000 on the host, so the address you already know still works.
EXPOSE 8080
ENV ASPNETCORE_URLS=http://+:8080

# Development turns on Swagger at /swagger. For a POC that is worth having;
# compose can override it.
ENV ASPNETCORE_ENVIRONMENT=Development

ENTRYPOINT ["dotnet", "TagTrail.Api.dll"]
