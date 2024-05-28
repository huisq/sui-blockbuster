This repo features the blockbuster video renting shop where users can rent videos. 

    Shops: 
        A Shop is a global shared object that is managed by the shop owner. The shop object holds 
        items and the balance of SUI coins in the shop. 
    
    Shop ownership: 
        Ownership of the Shop object is represented by holding the shop owner capability object. 
        The shop owner has the ability to add items to the shop, unlist items, and withdraw from 
        the shop. 

    Adding items to a shop: 
        The shop owner can add items to their shop with the add_item function.

    Renting an item: 
        Anyone has the ability to rent an item that is listed. When an item is rented, the 
        user will receive item and has to pay a fee + deposit. The deposit will be returned if item is 
        returned within the time limit. 

    Unlisting an item: 
        The shop owner can unlist an item from their shop with the unlist_item function. When an 
        item is unlisted, it will no longer be available for renting.

    Returning an item: 
        Renter has the ability to rent an item that they have rented, provided that it hasn't expired. 
        The item will be burned.
        The deposit will be returned if return success. 

    Declaring an item has expired: 
        Anyone has the ability to call this function as long as they have the item object id. 
        The deposit will be transfered to the shop balance.

    Withdrawing from a shop: 
        The shop owner can withdraw SUI from their shop with the withdraw_from_shop function. The shop 
        owner can withdraw any amount from their shop that is equal to or below the total amount in 
        the shop. The amount withdrawn will be sent to the recipient address specified.