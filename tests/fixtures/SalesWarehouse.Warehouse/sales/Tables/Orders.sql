CREATE TABLE [sales].[Orders] (

    [OrderId] BIGINT NOT NULL, 
    [CustomerId] INT NOT NULL, 
    [Amount] DECIMAL (18, 2) NULL, 
    [OrderDate] DATE NULL
);
