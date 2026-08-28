# Build petsite from unmodified upstream source (aws-samples/one-observability-demo)
# Pinned to the ref passed via build arg for reproducibility. UPSTREAM_REF may be
# a branch, a tag, or a FULL 40-character commit SHA (a full SHA is what actually
# pins the build); an abbreviated SHA is not fetchable and fails the build.

# --- Build stage ---
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build

ARG UPSTREAM_ORG=aws-samples
ARG UPSTREAM_REPO=one-observability-demo
ARG UPSTREAM_REF=main

RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*

WORKDIR /src
# `git clone --branch` only accepts a branch or tag name, so a commit SHA fails
# with "Remote branch <sha> not found in upstream origin". Fetching the ref
# instead accepts all three kinds. Single RUN layer, so the `cd` and the failure
# of any step (&&-chained) still fail the build.
RUN git init repo \
    && cd repo \
    && git remote add origin https://github.com/${UPSTREAM_ORG}/${UPSTREAM_REPO}.git \
    && git fetch --depth 1 origin ${UPSTREAM_REF} \
    && git checkout FETCH_HEAD

# NOTE: upstream was restructured. At the pinned ref petsite lives under
# src/applications/microservices/petsite-net/petsite (previously
# PetAdoptions/petsite/petsite), so an older UPSTREAM_REF can break this path.
WORKDIR /src/repo/src/applications/microservices/petsite-net/petsite
RUN dotnet restore
RUN dotnet publish -c Release -o /app/publish --no-restore

# --- Runtime stage ---
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime

WORKDIR /app
COPY --from=build /app/publish .

ENV ASPNETCORE_URLS=http://+:80
EXPOSE 80

ENTRYPOINT ["dotnet", "PetSite.dll"]
