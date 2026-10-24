
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF DB_ID(N'NetflixDB') IS NULL
    CREATE DATABASE NetflixDB;
GO

-- Simple recovery: no point-in-time restore needed, keeps the log small during bulk loads.
ALTER DATABASE NetflixDB SET RECOVERY SIMPLE;
GO

USE NetflixDB;
GO

IF SCHEMA_ID(N'stg')  IS NULL EXEC (N'CREATE SCHEMA stg');
IF SCHEMA_ID(N'core') IS NULL EXEC (N'CREATE SCHEMA core');
IF SCHEMA_ID(N'dw')   IS NULL EXEC (N'CREATE SCHEMA dw');
GO
