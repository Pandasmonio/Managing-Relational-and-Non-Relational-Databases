/************************************************************************************************************************************************************************
Schema:				Auction

Tables:				Auction.Auction_Products
					Auction.Threshold
					Auction.Bid

Procedures:         uspAddProductToAuction 
					uspTryBidProduct 
					uspRemoveProductFromAuction
					uspListBidsOffersHistory

Create Date:        2023-04-20
Authors:            Carolina Buracas
					Diogo Charola
					Gonçalo Eloy
					Mariana Pereira

Description:        Extension to the AventureWorks database schema, with table and stored procedures creation to allow
                    for a functional auction of products sold by AventureWorks

Commentary:         Additional description and comments to the code are made along the Script in the respective tables and stored procedures

**************************************************************************************************************************************************************************/


--- Create Auction Schema (working areas)
Create Schema Auction;
GO

/* 

CREATING OUR TABLES 

*/

IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Auction_Products')
BEGIN
CREATE TABLE Auction.Auction_Products
(
    AuctionID INT IDENTITY(1,1) PRIMARY KEY,
    ProductID INT NOT NULL,
    InitialBidPrice MONEY,
    ExpireDate DATETIME,
	BidStatus varchar(20) NOT NULL DEFAULT 'Active',
    CONSTRAINT FK_ProductID FOREIGN KEY (ProductID) REFERENCES Production.Product (ProductID)
)
END

-------------------------------------------------------------------------------- Creating our Bid History Table --------------------------------------------------------------------------------



IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Bid')
BEGIN	
	CREATE TABLE Auction.Bid (
		BidID INT IDENTITY (1,1) PRIMARY KEY,
		ProductID INT FOREIGN KEY REFERENCES Production.Product(ProductID),
		CustomerID INT FOREIGN KEY REFERENCES Sales.Customer(CustomerID),
		BidAmount MONEY NOT NULL,
		CurrentPrice Money NOT NULL,
		BidStatus varchar(20) NOT NULL DEFAULT 'Active',
		BidTime DATETIME,
		ExpireDate DATETIME,
		
		
		);
END

-------------------------------------------------------------------------------- THRESHOLD TABLE --------------------------------------------------------------------------------

IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Threshold')
BEGIN
	CREATE TABLE Auction.Threshold (       
		ProductID INT PRIMARY KEY REFERENCES Production.Product(ProductID),
		ListPrice MONEY NOT NULL,
		MakeFlag BIT,
		MinBid MONEY DEFAULT 0.05,
		MaxBid MONEY  not null
);
END

GO


/*  
										STORED PROCEDURE 1

*/
--- 1) create the store procedure
IF OBJECT_ID('Auction.uspAddProductToAuction', 'P') IS NOT NULL
    DROP PROCEDURE Auction.uspAddProductToAuction;
GO
CREATE PROCEDURE Auction.uspAddProductToAuction
	@ProductID INT,                 --- store procedure parameters
    @ExpireDate datetime = NULL,
    @InitialBidPrice money = NULL
AS
BEGIN
    -- Procedure body
	--- add a product to the auction but 1st check if the product is currently commercializer
	IF NOT EXISTS (                    ---IF NOT EXISTS is a conditional statement that checks whether a given condition is true or false.
    SELECT * 
    FROM Production.Product                 
    WHERE ProductID = @ProductID 
        AND SellEndDate IS NULL                   ---- are currently commercialized (both SellEndDate and DiscontinuedDate values not set)
        AND DiscontinuedDate IS NULL
    )
    BEGIN
       RAISERROR('Product is not currently commercialized', 16, 1) --- error in case the not commercialized
       RETURN                                                      --- 16 is the severity level and 1 a state error
    END

   --- if they are currently on the auction, goal not repeat products
    IF EXISTS (                
       SELECT * 
       FROM Auction.Auction_Products 
       WHERE ProductID = @ProductID
    )
    BEGIN
        RAISERROR('Product is already listed in the auction', 16, 1) --- and if yes this mensage will appear
        RETURN                                                       --- statement then exits the stored procedure without executing any further statements
    END

    ---- if the product is not in the auction, we can calculate the InitialBidPrice based on the MakeFlag
DECLARE @ListPrice MONEY
	DECLARE @MakeFlag BIT       

	SELECT @ListPrice = P.ListPrice, @MakeFlag = P.MakeFlag 
	FROM Production.Product P
	WHERE P.ProductID = @ProductID

	DECLARE @InitialPrice money

	IF @MakeFlag = 0
		SET @InitialPrice = @ListPrice * 0.75
	ELSE
		SET @InitialPrice = @ListPrice * 0.5

	IF @ExpireDate IS NULL              
		SET @ExpireDate = DATEADD(day, 7, GETDATE())

	IF @InitialBidPrice IS NULL
		SET @InitialBidPrice = @InitialPrice 
    

	---- Insert the product into the aution table
	SET IDENTITY_INSERT Auction.Auction_Products ON;
	INSERT INTO Auction.Auction_Products (AuctionID, ProductID, InitialBidPrice, ExpireDate, BidStatus)
	VALUES (ISNULL((SELECT MAX(AuctionID) FROM Auction.Auction_Products), 0) + 1, @ProductID, @InitialBidPrice, @ExpireDate, 'Active');
    
	--- Insert the Threshold table for this product
    INSERT INTO Auction.Threshold (ProductID, ListPrice, MakeFlag, MinBid, MaxBid)
    VALUES (@ProductID, @InitialBidPrice, @MakeFlag, 0.05, @InitialBidPrice);

	SELECT * FROM Auction.Auction_Products ORDER BY ExpireDate DESC;

END
GO





/*  
										STORED PROCEDURE 2

*/

-- Make Stored Procedure indepotent -------
IF OBJECT_ID('Auction.uspTryBidProduct', 'P') IS NOT NULL
    DROP PROCEDURE Auction.uspTryBidProduct;
GO

CREATE PROCEDURE Auction.uspTryBidProduct
    @ProductID INT,
    @CustomerID INT,
    @BidAmount MONEY = NULL
AS
BEGIN
    DECLARE @CurrentPrice MONEY;
    DECLARE @MinBid MONEY;
    DECLARE @MaxBid MONEY;


	   IF NOT EXISTS(SELECT * FROM Auction.Auction_Products WHERE ProductID = @ProductID)
    BEGIN
        RAISERROR('Product not found in auction.', 16, 1);
        RETURN;
    END;

	-- check if product exists in threshold
    IF NOT EXISTS(SELECT * FROM Auction.Threshold WHERE ProductID = @ProductID)
    BEGIN
        RAISERROR('Product not found in threshold.', 16, 1);
        RETURN;
    END;

  SELECT @CurrentPrice = CASE 
                           WHEN b.CurrentPrice IS NULL THEN t.ListPrice 
                           ELSE b.CurrentPrice 
                       END,
       @MinBid = t.MinBid,
       @MaxBid = t.MaxBid
FROM Auction.Threshold t
LEFT JOIN (SELECT TOP 1 CurrentPrice FROM Auction.Bid WHERE ProductID = @ProductID ORDER BY BidTime DESC) b ON 1=1
WHERE t.ProductID = @ProductID;

    IF @BidAmount IS NULL
    BEGIN
        SET @BidAmount = @MinBid;
    END;

    IF @BidAmount < @MinBid
    BEGIN
        RAISERROR('Bid amount must be greater than or equal to the Minimum Bid.', 16, 1);
        RETURN;
    END;

    IF @BidAmount > @MaxBid
    BEGIN
        RAISERROR('Bid amount exceeds maximum allowed.', 16, 1);
        RETURN;
    END;
	
	INSERT INTO Auction.Bid (ProductID, CustomerID, BidAmount, BidTime, CurrentPrice, BidStatus, ExpireDate)
	SELECT @ProductID, @CustomerID, @BidAmount, GETDATE(), @CurrentPrice + @BidAmount, 'Active', ap.ExpireDate
	FROM Auction.Auction_Products ap
	WHERE ap.ProductID = @ProductID;

    IF @@ROWCOUNT <> 1
    BEGIN
        RAISERROR('Error inserting bid.', 16, 1);
        RETURN;
    END;

    UPDATE Auction.Bid
    SET BidStatus = 'Inactive'
    WHERE BidID NOT IN (
        SELECT MAX(BidID)
        FROM Auction.Bid
        WHERE ProductID IN (SELECT ProductID FROM Auction.Auction_Products WHERE BidStatus = 'Active')
        GROUP BY ProductID
    );

    SELECT * FROM Auction.Bid WHERE BidID = SCOPE_IDENTITY();

    SELECT * FROM Auction.Bid ORDER BY BidTime DESC;

END;
GO



/*  
										STORED PROCEDURE 3

*/
-- Make Stored Procedure indepotent -------

IF OBJECT_ID('Auction.uspRemoveProductFromAuction', 'P') IS NOT NULL
    DROP PROCEDURE Auction.uspRemoveProductFromAuction;
GO
--- 3) create the store procedure
CREATE PROCEDURE Auction.uspRemoveProductFromAuction
    @ProductID int                    ---store procedure parameter

AS
BEGIN
    
    IF NOT EXISTS (                        --- Check if product is currently auctioned and if not raise the error
        SELECT *
        FROM Auction.Auction_Products
        WHERE ProductID = @ProductID
        AND ExpireDate > GETDATE()        --- Checks if the current date and time are less than the ExpireDate, meaning auction is still active
    )

    BEGIN
        RAISERROR ('Product is not currently being auctioned', 16, 1)    
        RETURN
    END

    --- Remove the product from Auction_Products table if the product is being auctioned
    DELETE FROM Auction.Auction_Products             
    WHERE ProductID = @ProductID

    --- Update the bid history to set BidStatus to cancelled, and to ensure that the user see that their bids were cancelled
    UPDATE Auction.Bid
    SET BidStatus = 'Cancelled'
    WHERE ProductID = @ProductID   --- Uptade only bids for the specified product
    AND BidStatus = 'Active'       --- Garanty that only active bids are cancelled

	  --- Delete the threshold data for the product being removed
    DELETE FROM Auction.Threshold
	WHERE ProductID = @ProductID
    END
	GO
/*  
										STORED PROCEDURE 4

*/


IF OBJECT_ID('Auction.uspListBidsOffersHistory', 'P') IS NOT NULL
    DROP PROCEDURE Auction.uspListBidsOffersHistory;
GO
--- 4) create the store procedure
CREATE PROCEDURE Auction.uspListBidsOffersHistory
	@CustomerID INT,
	@StartTime DATETIME,
	@EndTime DATETIME,
	@Active BIT = 1
AS
BEGIN
	SET NOCOUNT ON;

	IF @Active = 1
	BEGIN
		SELECT *
		FROM 
			Auction.Bid 
		WHERE 
			CustomerID = @CustomerID 
			AND BidTime BETWEEN @StartTime AND @EndTime 
			AND BidStatus = 'Active' 
	END
	ELSE
	BEGIN
		SELECT *
		FROM 
			Auction.Bid 
		WHERE 
			CustomerID = @CustomerID 
			AND BidTime BETWEEN @StartTime AND @EndTime 
	END
END

GO

/*  
										STORED PROCEDURE 5

*/





IF OBJECT_ID('Auction.uspUpdateProductAuctionStatus', 'P') IS NOT NULL
    DROP PROCEDURE Auction.uspUpdateProductAuctionStatus;
GO
CREATE PROCEDURE Auction.uspUpdateProductAuctionStatus
AS
BEGIN
    SET NOCOUNT ON;

    -- Update auction status for products with bids
    UPDATE Auction.Auction_Products
    SET BidStatus = 'Sold'
    WHERE ProductID IN (
        SELECT DISTINCT p.ProductID 
        FROM Auction_Products p 
        INNER JOIN Bid b ON p.ProductID = b.ProductID 
        WHERE b.BidAmount = (SELECT MAX(BidAmount) FROM Bid WHERE ProductID = p.ProductID)
        AND b.BidStatus = 'Active'
        AND p.ExpireDate < GETDATE()
    );

    -- Update auction status for products with no bids but expired auction date
    UPDATE Auction_Products
    SET BidStatus = 'Expired'
    WHERE ProductID IN (
        SELECT ProductID 
        FROM Auction_Products
        WHERE BidStatus = 'In Auction' 
        AND ExpireDate < GETDATE() 
        AND NOT EXISTS (
            SELECT *
            FROM Bid
            WHERE ProductID = Auction_Products.ProductID
        )
    );

    -- Update bid status for expired bids
    UPDATE Bid
    SET BidStatus = 'Expired'
    WHERE BidStatus = 'Active' 
    AND ProductID IN (
        SELECT ProductID 
        FROM Auction_Products
        WHERE BidStatus = 'Expired'
    );

    -- Update bid status for winning bids
    UPDATE Bid
    SET BidStatus = 'Won'
    WHERE BidStatus= 'Active' 
    AND BidAmount = (SELECT MAX(BidAmount) FROM Bid WHERE ProductID = Bid.ProductID)
    AND ProductID IN (
        SELECT ProductID 
        FROM Auction_Products
        WHERE BidStatus = 'Sold'
    );
END