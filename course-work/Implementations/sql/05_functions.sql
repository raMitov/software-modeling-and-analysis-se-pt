/* =============================================================================
   05_functions.sql
   fn_ConvertToUSD        - scalar: local amount -> USD on a given date
   fn_ActiveSubscriptions - inline table-valued: subscriptions active on a date
   Re-runnable (CREATE OR ALTER).
   ============================================================================= */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE NetflixDB;
GO

/* Converts an amount in @CurrencyCode to USD using the latest rate on or
   before @OnDate (covers days without a published rate).
   Returns NULL when no rate exists for that currency/date. */
CREATE OR ALTER FUNCTION core.fn_ConvertToUSD
(
    @Amount       DECIMAL(10,2),
    @CurrencyCode CHAR(3),
    @OnDate       DATE
)
RETURNS DECIMAL(12,2)
WITH SCHEMABINDING
AS
BEGIN
    -- single RETURN expression keeps the function eligible for scalar UDF inlining
    RETURN CASE
               WHEN @CurrencyCode = 'USD' THEN @Amount
               ELSE
               (
                   SELECT CAST(ROUND(@Amount * er.RateToUSD, 2) AS DECIMAL(12,2))
                   FROM core.ExchangeRate AS er
                   WHERE er.CurrencyCode = @CurrencyCode
                     AND er.RateDate = (SELECT MAX(x.RateDate)
                                        FROM core.ExchangeRate AS x
                                        WHERE x.CurrencyCode = @CurrencyCode
                                          AND x.RateDate <= @OnDate)
               )
           END;
END;
GO

/* Subscriptions active on @OnDate (half-open period: StartDate <= date < EndDate).
   Inline TVF: expanded into the caller's query plan, so it stays set-based. */
CREATE OR ALTER FUNCTION core.fn_ActiveSubscriptions
(
    @OnDate DATE
)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT s.SubscriptionID,
           s.AccountID,
           s.PlanID,
           s.StartDate,
           s.EndDate
    FROM core.Subscription AS s
    WHERE s.StartDate <= @OnDate
      AND (s.EndDate IS NULL OR s.EndDate > @OnDate);
GO
