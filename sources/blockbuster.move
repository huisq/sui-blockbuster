/* 
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

    Withdrawing from a shop: 
        The shop owner can withdraw SUI from their shop with the withdraw_from_shop function. The shop 
        owner can withdraw any amount from their shop that is equal to or below the total amount in 
        the shop. The amount withdrawn will be sent to the recipient address specified.    
*/
#[allow(unused_variable, lint(self_transfer, share_owned))]
module admin::blockbuster {
    //==============================================================================================
    // Dependencies
    //==============================================================================================
    use sui::coin;
    use sui::event;
    use std::vector;
    use sui::table::{Self, Table};
    use sui::sui::SUI;
    use sui::transfer;
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use std::string::{Self, String};
    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};

    #[test_only]
    use sui::test_scenario;
    #[test_only]
    use sui::test_utils::assert_eq;

    //==============================================================================================
    // Constants - Add your constants here (if any)
    //==============================================================================================

    const DEPOSIT: u64 = 10000000; //10 SUI

    //==============================================================================================
    // Error codes - DO NOT MODIFY
    //==============================================================================================
    const ENotShopOwner: u64 = 1;
    const EInvalidWithdrawalAmount: u64 = 2;
    const EItemExpired: u64 = 3;
    const EItemNotExpired: u64 = 4;
    const EInvalidItemId: u64 = 5;
    const EInvalidPrice: u64 = 6;
    const EInsufficientPayment: u64 = 7;
    const EItemIsNotListed: u64 = 8;
    const EAlreadyRented: u64 = 9;
    const EInvalidRecipient: u64 = 10;

    //==============================================================================================
    // Module Structs - DO NOT MODIFY
    //==============================================================================================

    /*
        The shop struct represents a shop in the marketplace. A shop is a global shared object that
        is managed by the shop owner. The shop owner is designated by the ownership of the shop
        owner capability. 
        @param id - The object id of the shop object.
        @param shop_owner_cap - The object id of the shop owner capability.
        @param balance - The balance of SUI coins in the shop. (profit)
        @param deposit - The locked deposit of SUI coins in the shop.
        @param items - The items in the shop.
        @param item_count - The number of items in the shop. Including items that are not listed or 
            sold out.
    */
	struct Shop has key {
		id: UID,
        shop_owner_cap: ID,
		balance: Balance<SUI>,
        deposit: Balance<SUI>,
		items: Table<u64, InStoreItem>,
        item_count: u64,
        item_added_count: u64,
	}

    /*
        The shop owner capability struct represents the ownership of a shop. The shop
        owner capability is an object that is owned by the shop owner and is used to manage the shop.
        @param id - The object id of the shop owner capability object.
        @param shop - The object id of the shop object.
    */
    struct ShopOwnerCapability has key {
        id: UID,
        shop: ID,
    }

    /*
        The item struct represents an item transferred when rented out. 
        @param id - The object id of the item object.
        @param title - The title of the item.
        @param description - The description of the item.
        @param price - The price of the item (price per each quantity per day).
        @param expiry - Expiry timestamp
        @param renter - Who rented it.
        @param category - The category of the item.
    */
    struct Item has key {
		id: UID,
        item_index: u64,
		title: String,
		description: String,
		price: u64,
		expiry: u64,
        category: u8,
        renter: address,
    }

    /*
        The item struct represents an item transferred when rented out. 
        @param id - The object id of the item object.
        @param title - The title of the item.
        @param description - The description of the item.
        @param price - The price of the item (price per each quantity per day).
        @param expiry - Expiry timestamp
        @param listed - Whether the item is listed. If the item is not listed, it will not be 
            available for rent.
        @param category - The category of the item.
    */
    struct InStoreItem has store, drop {
		index: u64,
		title: String,
		description: String,
		price: u64,
        listed: bool,
        category: u8,
    }

    //==============================================================================================
    // Event structs - DO NOT MODIFY
    //==============================================================================================

    /*
        Event to be emitted when an item is added to a shop.
        @param item - The id of the item object.
    */
    struct ItemAdded has copy, drop {
        shop_id: ID,
        item_index: u64,
    }

    /*
        Event to be emitted when an item is rented.
        @param item - The id of the item object.
        @param days - The number of days which the item rented.
        @param renter - The address of the renter.
    */
    struct ItemRented has copy, drop {
        shop_id: ID,
        item_index: u64, 
        days: u64,
        renter: address,
    }

    /*
        Event to be emitted when an item is returned.
        @param item - The id of the item object.
        @param return_timestamp - The time of the item is returned.
        @param renter - The address of the renter.
    */
    struct ItemReturned has copy, drop {
        shop_id: ID,
        item_index: u64, 
        return_timestamp: u64,
        renter: address,
    }

    /*
        Event to be emitted when an item is expired.
        @param item - The id of the item object.
        @param renter - The address of the renter.
    */
    struct ItemExpired has copy, drop {
        shop_id: ID,
        item_index: u64, 
        renter: address,
    }

    /*
        Event to be emitted when an item is unlisted.
        @param item - The id of the item object.
    */
    struct ItemUnlisted has copy, drop {
        shop_id: ID,
        item_index: u64, 
    }

    /*
        Event to be emitted when a shop owner withdraws from their shop.
        @param shop_id - The id of the shop object.
        @param amount - The amount withdrawn.
        @param recipient - The address of the recipient of the withdrawal.
    */
    struct ShopWithdrawal has copy, drop {
        shop_id: ID,
        amount: u64,
        recipient: address,
    }

    //==============================================================================================
    // Functions
    //==============================================================================================

	/*
        Creates a new shop for the recipient and emits a ShopCreated event.
        @param recipient - The address of the recipient of the shop.
        @param ctx - The transaction context.
	*/
	public entry fun create_shop(recipient: address, ctx: &mut TxContext) {
        let id = object::new(ctx);
        let shop_id = object::uid_to_inner(&id);
        transfer::share_object(Shop {
            id,
            shop_owner_cap: shop_id,
            balance: balance::zero(),
            deposit: balance::zero(),
            items: table::new<u64, InStoreItem>(ctx),
            item_count: 0,
            item_added_count: 0,
        });
        let shop_owner_cap = ShopOwnerCapability {
            id: object::new(ctx),
            shop: shop_id,
        };
        transfer::transfer(shop_owner_cap, recipient);
	}

    /*
        Adds a new item to the shop and emits an ItemAdded event. Abort if the shop owner capability
        does not match the shop, if the price is not above 0.
        @param shop - The shop to add the item to.
        @param shop_owner_cap - The shop owner capability of the shop.
        @param title - The title of the item.
        @param description - The description of the item.
        @param price - The price of the item.
        @param category - The category of the item.
        @param ctx - The transaction context.
    */
    public entry fun add_item(
        shop: &mut Shop,
        shop_owner_cap: &ShopOwnerCapability, 
        title: vector<u8>,
        description: vector<u8>,
        price: u64,
        category: u8, 
        ctx: &mut TxContext
    ) {
        let shop_id = sui::object::uid_to_inner(&shop.id);
        assert_shop_owner(shop_owner_cap.shop, shop_id);
        assert_price_more_than_0(price);
        let index = shop.item_added_count;
        let item = InStoreItem {
            index,
            title: string::utf8(title),
            description: string::utf8(description),
            price,
            listed: true,
            category,
	    };
        table::add(&mut shop.items, index, item);
        shop.item_added_count = shop.item_added_count + 1;
        event::emit(ItemAdded {
            shop_id,
            item_index: index,
        });
        shop.item_count = shop.item_count + 1;
    }

    /*
        Unlists an item from the shop and emits an ItemUnlisted event. Abort if the shop owner 
        capability does not match the shop or if the item id is invalid.
        @param shop - The shop to unlist the item from.
        @param shop_owner_cap - The shop owner capability of the shop.
        @param item_index - The item to unlist.
    */
    public entry fun unlist_item(
        shop: &mut Shop,
        shop_owner_cap: &ShopOwnerCapability,
        item_index: u64
    ) {
        let shop_id = sui::object::uid_to_inner(&shop.id);
        assert_shop_owner(shop_owner_cap.shop, shop_id);
        assert_item_index_valid(item_index, &shop.items);
        let item = table::borrow_mut(&mut shop.items, item_index);
        item.listed = false;
        shop.item_count = shop.item_count - 1;
        event::emit(ItemUnlisted {
            shop_id,
            item_index,
        });
    }

    /*
        Rent an item from the shop and emits an ItemRented event. Abort if the item id is
        invalid, the payment coin is insufficient, or if the item is unlisted.
        @param shop - The shop to rent the item from.
        @param item_index - The item to rent.
        @param days - The number of days to rent the item for.
        @param recipient - The address of the recipient of the item.
        @param payment_coin - The payment coin for the item.
        @param clock - Clock module to determine current timestamp.
        @param ctx - The transaction context.
    */
    public entry fun rent_item(
        shop: &mut Shop, 
        item_index: u64,
        days: u64,
        recipient: address,
        payment_coin: coin::Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert_item_index_valid(item_index, &shop.items);
        let shop_id = sui::object::uid_to_inner(&shop.id);
        let item = table::borrow_mut(&mut shop.items, item_index);
        assert_item_listed(item.listed);
        assert!(item.renter == address::zero(), EAlreadyRented);
        let total_price = item.price * days + DEPOSIT;
        assert_correct_payment(coin::value(&payment_coin), total_price);
        let coin_balance = coin::into_balance(payment_coin);
        let paid_fee = balance::split(&mut coin_balance, item.price * days);
        balance::join(&mut shop.balance, paid_fee);
        balance::join(&mut shop.deposit, coin_balance);
        let id = sui::object::new(ctx);
        let rented_item = Item {
            id,
            item_index, 
            title: item.title.clone(),
            description: item.description.clone(),
            price: item.price,
            expiry: clock::timestamp_ms(clock) + days * 86400000,
            category: item.category,
            renter: recipient,
	    };
        transfer::transfer(rented_item, recipient);
        item.listed = false;
        event::emit(ItemRented {
            shop_id,
            item_index, 
            days,
            renter: recipient,
        });
    }

    /*
        Return an item to the shop and emits an ItemReturned event. Abort if the item id is
        invalid, if the item is expired.
        @param shop - The shop to rent the item from.
        @param item - The item to return.
        @param clock - Clock module to determine current timestamp.
        @param ctx - The transaction context.
    */
    public entry fun return_item(
        shop: &mut Shop, 
        item: Item,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let item_index = item.item_index;
        assert_item_index_valid(item_index, &shop.items);
        let shop_id = sui::object::uid_to_inner(&shop.id);
        let sender = tx_context::sender(ctx);
        let return_timestamp = clock::timestamp_ms(clock);
        assert_item_not_expired(item.expiry, return_timestamp);
        burn(item, ctx);
        let in_store_item = table::borrow_mut(&mut shop.items, item_index);
        in_store_item.listed = true;
        transfer::public_transfer(coin::take(&mut shop.deposit, DEPOSIT, ctx), sender);
        event::emit(ItemReturned {
            shop_id,
            item_index, 
            return_timestamp,
            renter: sender,
        });
    }

    /*
        Removes an expired item from the shop and emits an ItemExpired event. Abort if the item id is
        invalid.
        @param shop - The shop to rent the item from.
        @param item - The item to return.
        @param clock - Clock module to determine current timestamp.
        @param ctx - The transaction context.
    */
    public entry fun item_expired(
        shop: &mut Shop, 
        item: &Item,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert_item_index_valid(item.item_index, &shop.items);
        let shop_id = sui::object::uid_to_inner(&shop.id);
        let return_timestamp = clock::timestamp_ms(clock);
        assert_item_expired(item.expiry, return_timestamp);
        balance::join(&mut shop.balance, balance::split(&mut shop.deposit, DEPOSIT));
        table::remove(&mut shop.items, item.item_index);
        event::emit(ItemExpired {
            shop_id,
            item_index: item.item_index, 
            renter: item.renter,
        });
    }

    /*
        Withdraws SUI from the shop to the recipient and emits a ShopWithdrawal event. Abort if the 
        shop owner capability does not match the shop or if the amount is invalid.
        @param shop - The shop to withdraw from.
        @param shop_owner_cap - The shop owner capability of the shop.
        @param amount - The amount to withdraw.
        @param recipient - The address of the recipient of the withdrawal.
        @param ctx - The transaction context.
    */
    public entry fun withdraw_from_shop(
        shop: &mut Shop,
        shop_owner_cap: &ShopOwnerCapability,
        amount: u64,
        recipient: address,
        ctx: &mut TxContext
    ) {
        let shop_id = sui::object::uid_to_inner(&shop.id);
        assert_shop_owner(shop_owner_cap.shop, shop_id);
        let balance = balance::value(&shop.balance);
        assert_valid_withdrawal_amount(amount, balance);
        let withdrawal = coin::take(&mut shop.balance, amount, ctx);
        assert!(recipient != address::zero(), EInvalidRecipient);
        transfer::public_transfer(withdrawal, recipient);
        event::emit(ShopWithdrawal {
            shop_id,
            amount,
            recipient,
        });
    }

    //==============================================================================================
    // Helper functions - Add your helper functions here (if any)
    //==============================================================================================
    /// Permanently delete `nft`
    public entry fun burn(nft: Item, _: &mut TxContext) {
        let Item { 
            id,
            item_index: _, 
            title: _,
            description: _,
            price: _,
            expiry: _,
            category: _,
            renter: _
        } = nft;
        object::delete(id);
    }

    //==============================================================================================
    // Validation functions - Add your validation functions here (if any)
    //==============================================================================================

    fun assert_shop_owner(cap_id: ID, shop_id: ID) {
        assert!(cap_id == shop_id, ENotShopOwner);
    }

    fun assert_price_more_than_0(price: u64) {
        assert!(price > 0, EInvalidPrice);
    }
    
    fun assert_item_listed(status: bool) {
        assert!(status, EItemIsNotListed);
    }

    fun assert_item_index_valid(item_index: u64, items: &Table<u64, InStoreItem>) {
        assert!(table::contains(items, item_index), EInvalidItemId);
    }

    fun assert_correct_payment(payment: u64, price: u64) {
        assert!(payment == price, EInsufficientPayment);
    }

    fun assert_valid_withdrawal_amount(amount: u64, balance: u64) {
        assert!(amount <= balance, EInvalidWithdrawalAmount);
    }

    fun assert_item_not_expired(expiry: u64, return_timestamp: u64) {
        assert!(return_timestamp < expiry, EItemExpired);
    }

    fun assert_item_expired(expiry: u64, return_timestamp: u64) {
        assert!(return_timestamp > expiry, EItemNotExpired);
    }

    //==============================================================================================
    // Tests - DO NOT MODIFY
    //==============================================================================================
    #[test]
    public fun test_create_shop_success_create_shop_for_user() {
        let shop_owner = @0xa;

        let scenario_val = test_scenario::begin(shop_owner);
        let scenario = &mut scenario_val;

        {
            create_shop(shop_owner, test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, shop_owner);
        {
            let shop_owner_cap = test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop = test_scenario::take_shared<Shop>(scenario);

            assert_eq(shop_owner_cap.shop, sui::object::uid_to_inner(&shop.id));
            
            test_scenario::return_to_sender(scenario, shop_owner_cap);
            test_scenario::return_shared(shop);
        };
        let tx = test_scenario::end(scenario_val);
    }

    #[test]
    public fun test_create_shop_success_create_multiple_shops_for_user() {
        let shop_owner = @0xa;

        let scenario_val = test_scenario::begin(shop_owner);
        let scenario = &mut scenario_val;

        {
            create_shop(shop_owner, test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, shop_owner);
        {
            let shop_owner_cap = test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop = test_scenario::take_shared<Shop>(scenario);

            assert_eq(shop_owner_cap.shop, sui::object::uid_to_inner(&shop.id));
            
            test_scenario::return_to_sender(scenario, shop_owner_cap);
            test_scenario::return_shared(shop);
        };
       
        {
            create_shop(shop_owner, test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, shop_owner);
        {
            let shop_owner_cap = test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop = test_scenario::take_shared<Shop>(scenario);

            assert_eq(shop_owner_cap.shop, sui::object::uid_to_inner(&shop.id));
            
            test_scenario::return_to_sender(scenario, shop_owner_cap);
            test_scenario::return_shared(shop);
        };
        
        {
            create_shop(shop_owner, test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, shop_owner);
        {
            let shop_owner_cap = test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop = test_scenario::take_shared<Shop>(scenario);

            assert_eq(shop_owner_cap.shop, sui::object::uid_to_inner(&shop.id));
            
            test_scenario::return_to_sender(scenario, shop_owner_cap);
            test_scenario::return_shared(shop);
        };
        let tx = test_scenario::end(scenario_val);
    }

    #[test]
    public fun test_create_shop_success_shop_for_multiple_users() {
        let user1 = @0xa;
        let user2 = @0xb;

        let scenario_val = test_scenario::begin(user1);
        let scenario = &mut scenario_val;
        {
            create_shop(user1, test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, user1);
        {
            let shop_owner_cap_of_user_1 = test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop_of_user_1 = test_scenario::take_shared<Shop>(scenario);

            assert_eq(shop_owner_cap_of_user_1.shop, sui::object::uid_to_inner(&shop_of_user_1.id));
            
            test_scenario::return_to_sender(scenario, shop_owner_cap_of_user_1);
            test_scenario::return_shared(shop_of_user_1);
        };
        {
            create_shop(user2, test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, user2);
        {
            let shop_owner_cap_of_user_2 = test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop_of_user_2 = test_scenario::take_shared<Shop>(scenario);

            assert_eq(shop_owner_cap_of_user_2.shop, sui::object::uid_to_inner(&shop_of_user_2.id));
            
            test_scenario::return_to_sender(scenario, shop_owner_cap_of_user_2);
            test_scenario::return_shared(shop_of_user_2);
        };

        let tx = test_scenario::end(scenario_val);
    }

    #[test]
    public fun test_add_item_success_added_one_item() {
        let shop_owner = @0xa;

        let scenario_val = test_scenario::begin(shop_owner);
        let scenario = &mut scenario_val;

        {
            create_shop(shop_owner, test_scenario::ctx(scenario));
        };
        
        let expected_title = b"title";
        let expected_description = b"description";
        let expected_price = 1000000000; // 1 SUI
        let expected_category = 3;
        
        test_scenario::next_tx(scenario, shop_owner);
        {
            let shop_owner_cap  = 
                test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop = test_scenario::take_shared<Shop>(scenario);

            add_item(
                &mut shop, 
                &shop_owner_cap,
                expected_title, 
                expected_description, 
                expected_price, 
                expected_category,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, shop_owner_cap);
            test_scenario::return_shared(shop);
        };
        let tx = test_scenario::next_tx(scenario, shop_owner);
        let expected_events_emitted = 1;
        assert_eq(
            test_scenario::num_user_events(&tx),
            expected_events_emitted
        );

        {
            let expected_item_length = 1;

            let shop = test_scenario::take_shared<Shop>(scenario);
            let item = table::borrow(&shop.items, 0);

            assert_eq(table::length(&shop.items), expected_item_length);

            assert_eq(item.title, string::utf8(expected_title));
            assert_eq(item.description, string::utf8(expected_description));
            assert_eq(item.price, expected_price);
            assert_eq(item.category, expected_category);
            assert_eq(item.listed, true);

            test_scenario::return_shared(shop);
        };
        let tx = test_scenario::end(scenario_val);
        let expected_events_emitted = 0;
        assert_eq(
            test_scenario::num_user_events(&tx),
            expected_events_emitted
        );

    }

    #[test, expected_failure(abort_code = EInvalidPrice)]
    public fun test_add_item_failure_zero_price() {
        let shop_owner = @0xa;

        let scenario_val = test_scenario::begin(shop_owner);
        let scenario = &mut scenario_val;

        {
            create_shop(shop_owner, test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, shop_owner);

        let expected_title = b"title";
        let expected_description = b"description";
        let expected_price = 0; 
        let expected_category = 3;
        {
            let shop_owner_cap  = 
                test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop = test_scenario::take_shared<Shop>(scenario);

            add_item(
                &mut shop, 
                &shop_owner_cap,
                expected_title, 
                expected_description, 
                expected_price, 
                expected_category,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, shop_owner_cap);
            test_scenario::return_shared(shop);
        };
        test_scenario::end(scenario_val);
    }


    #[test]
    public fun test_add_item_success_added_multiple_items() {
        let shop_owner = @0xa;

        let scenario_val = test_scenario::begin(shop_owner);
        let scenario = &mut scenario_val;

        {
            create_shop(shop_owner, test_scenario::ctx(scenario));
        };

        {
            let expected_title = b"title";
            let expected_description = b"description";
            let expected_price = 1000000000; // 1 SUI
            let expected_category = 3;
            test_scenario::next_tx(scenario, shop_owner);
            {
                let shop_owner_cap  = 
                    test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
                let shop = test_scenario::take_shared<Shop>(scenario);

                add_item(
                    &mut shop, 
                    &shop_owner_cap,
                    expected_title, 
                    expected_description, 
                    expected_price, 
                    expected_category,
                    test_scenario::ctx(scenario)
                );

                test_scenario::return_to_sender(scenario, shop_owner_cap);
                test_scenario::return_shared(shop);
            };

            test_scenario::next_tx(scenario, shop_owner);
            {

                let expected_item_length = 1;

                let shop = test_scenario::take_shared<Shop>(scenario);
                let item = table::borrow(&shop.items, 0);
                assert_eq(table::length(&shop.items), expected_item_length);

                assert_eq(item.title, string::utf8(expected_title));
                assert_eq(item.description, string::utf8(expected_description));
                assert_eq(item.price, expected_price);
                assert_eq(item.category, expected_category);
                assert_eq(item.listed, true);

                test_scenario::return_shared(shop);
            };
        };

        {
            let expected_title = b"adf";
            let expected_description = b"description";
            let expected_price = 45000000000; // 45 SUI
            let expected_category = 2;
            test_scenario::next_tx(scenario, shop_owner);
            {
                let shop_owner_cap  = 
                    test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
                let shop = test_scenario::take_shared<Shop>(scenario);

                add_item(
                    &mut shop, 
                    &shop_owner_cap,
                    expected_title, 
                    expected_description, 
                    expected_price, 
                    expected_category,
                    test_scenario::ctx(scenario)
                );

                test_scenario::return_to_sender(scenario, shop_owner_cap);
                test_scenario::return_shared(shop);
            };

            test_scenario::next_tx(scenario, shop_owner);
            {
                let expected_item_length = 2;
                let shop = test_scenario::take_shared<Shop>(scenario);
                let item = table::borrow(&shop.items, 1);

                assert_eq(table::length(&shop.items), expected_item_length);

                assert_eq(item.title, string::utf8(expected_title));
                assert_eq(item.description, string::utf8(expected_description));
                assert_eq(item.price, expected_price);
                assert_eq(item.category, expected_category);
                assert_eq(item.listed, true);

                test_scenario::return_shared(shop);
            };
        };

        {
            let expected_title = b"ready player one";
            let expected_description = b"so freaking awesome";
            let expected_price = 200000000; // .2 SUI
            let expected_category = 1;
            test_scenario::next_tx(scenario, shop_owner);
            {
                let shop_owner_cap  = 
                    test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
                let shop = test_scenario::take_shared<Shop>(scenario);

                add_item(
                    &mut shop, 
                    &shop_owner_cap,
                    expected_title, 
                    expected_description, 
                    expected_price, 
                    expected_category,
                    test_scenario::ctx(scenario)
                );

                test_scenario::return_to_sender(scenario, shop_owner_cap);
                test_scenario::return_shared(shop);
            };

            test_scenario::next_tx(scenario, shop_owner);
            {

                let expected_item_length = 3;

                let shop = test_scenario::take_shared<Shop>(scenario);
                let item = table::borrow(&shop.items, 2);

                assert_eq(table::length(&shop.items), expected_item_length);

                assert_eq(item.title, string::utf8(expected_title));
                assert_eq(item.description, string::utf8(expected_description));
                assert_eq(item.price, expected_price);
                assert_eq(item.category, expected_category);
                assert_eq(item.listed, true);

                test_scenario::return_shared(shop);
            };
        };

        test_scenario::end(scenario_val);
    }

    #[test, expected_failure(abort_code = ENotShopOwner)]
    public fun test_add_item_failure_wrong_shop_owner_cap() {
        let user1 = @0xa;
        let user2 = @0xb;

        let scenario_val = test_scenario::begin(user1);
        let scenario = &mut scenario_val;

        {
            create_shop(user2, test_scenario::ctx(scenario));
            create_shop(user1, test_scenario::ctx(scenario));
        };

        test_scenario::next_tx(scenario, user2);
        {
            let shop_owner_cap_of_user_2  = 
                test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop_of_user_1 = test_scenario::take_shared<Shop>(scenario);
            
            add_item(
                &mut shop_of_user_1, 
                &shop_owner_cap_of_user_2,
                b"title", 
                b"description", 
                1000000000, // 1 SUI
                3,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, shop_owner_cap_of_user_2);
            test_scenario::return_shared(shop_of_user_1);
        };
        test_scenario::end(scenario_val);
    }

    #[test]
    public fun test_rent_item_success_rent_one_item() {
        let shop_owner = @0xa;
        let renter = @0xb;

        let scenario_val = test_scenario::begin(shop_owner);
        let scenario = &mut scenario_val;
        
        {
            clock::share_for_testing(clock::create_for_testing(test_scenario::ctx(scenario)));
        };
        {
            create_shop(shop_owner, test_scenario::ctx(scenario));
        };
        
        test_scenario::next_tx(scenario, shop_owner);
        let expected_title = b"title";
        let expected_description = b"description";
        let expected_price = 1000; 
        let expected_category = 3;
        {
            let shop_owner_cap  = test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop = test_scenario::take_shared<Shop>(scenario);

            add_item(
                &mut shop, 
                &shop_owner_cap,
                expected_title, 
                expected_description, 
                expected_price, 
                expected_category,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, shop_owner_cap);
            test_scenario::return_shared(shop);
        };
    
        let tx = test_scenario::next_tx(scenario, shop_owner);
        let expected_events_emitted = 1;
        assert_eq(
            test_scenario::num_user_events(&tx),
            expected_events_emitted
        );

        test_scenario::next_tx(scenario, renter);
        {
            let shop = test_scenario::take_shared<Shop>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            let payment_coin = sui::coin::mint_for_testing<SUI>(
                expected_price + DEPOSIT, 
                test_scenario::ctx(scenario)
            );

            rent_item(
                &mut shop, 
                0,
                1,
                renter,
                payment_coin,
                &clock,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
            test_scenario::return_shared(shop);
        };

        let tx = test_scenario::next_tx(scenario, renter);
        let expected_events_emitted = 1;
        assert_eq(
            test_scenario::num_user_events(&tx),
            expected_events_emitted
        );
        {
            let shop = test_scenario::take_shared<Shop>(scenario);
            let item = test_scenario::take_from_sender<Item>(scenario);
            let in_store_item = table::borrow(&shop.items, 0);

            assert_eq(item.price, expected_price);
            assert_eq(balance::value(&shop.balance), item.price);
            assert_eq(item.renter, renter);
            assert_eq(item.expiry, 86400000);
            assert_eq(in_store_item.listed, false);

            assert_eq(
                vector::length(&test_scenario::ids_for_sender<Item>(scenario)), 
                1
            );

            test_scenario::return_shared(shop);
            test_scenario::return_to_sender(scenario, item);
        };
        let tx = test_scenario::end(scenario_val);
        let expected_events_emitted = 0;
        assert_eq(
            test_scenario::num_user_events(&tx),
            expected_events_emitted
        );
    }

    #[test, expected_failure(abort_code = EItemIsNotListed)]
    public fun test_rent_item_failure_item_is_unlisted() {
        let shop_owner = @0xa;
        let renter = @0xb;

        let scenario_val = test_scenario::begin(shop_owner);
        let scenario = &mut scenario_val;

        {
            clock::share_for_testing(clock::create_for_testing(test_scenario::ctx(scenario)));
        };
        {
            create_shop(shop_owner, test_scenario::ctx(scenario));
        };
        
        test_scenario::next_tx(scenario, shop_owner);
        let expected_price = 1000; 
        {
            let shop_owner_cap  = test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop = test_scenario::take_shared<Shop>(scenario);

            add_item(
                &mut shop, 
                &shop_owner_cap,
                b"title", 
                b"description", 
                expected_price, 
                3,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, shop_owner_cap);
            test_scenario::return_shared(shop);
        };

        test_scenario::next_tx(scenario, shop_owner);
        {
            let shop_owner_cap  = test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop = test_scenario::take_shared<Shop>(scenario);

            unlist_item(
                &mut shop,
                &shop_owner_cap,
                0
            );

            test_scenario::return_to_sender(scenario, shop_owner_cap);
            test_scenario::return_shared(shop);
        };
        
        test_scenario::next_tx(scenario, renter);
        {
            let shop = test_scenario::take_shared<Shop>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            let payment_coin = sui::coin::mint_for_testing<SUI>(
                expected_price + DEPOSIT, 
                test_scenario::ctx(scenario)
            );

            rent_item(
                &mut shop, 
                0,
                1,
                renter,
                payment_coin,
                &clock,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
            test_scenario::return_shared(shop);
        };
        test_scenario::end(scenario_val);
    }

    #[test, expected_failure(abort_code = EInsufficientPayment)]
    public fun test_rent_item_failure_insufficient_payment() {
        let shop_owner = @0xa;
        let renter = @0xb;

        let scenario_val = test_scenario::begin(shop_owner);
        let scenario = &mut scenario_val;
        
        {
            clock::share_for_testing(clock::create_for_testing(test_scenario::ctx(scenario)));
        };
        {
            create_shop(shop_owner, test_scenario::ctx(scenario));
        };
        
        test_scenario::next_tx(scenario, shop_owner);
        let expected_price = 1000; 
        {
            let shop_owner_cap  = test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop = test_scenario::take_shared<Shop>(scenario);

            add_item(
                &mut shop, 
                &shop_owner_cap,
                b"title", 
                b"description", 
                expected_price, 
                3,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, shop_owner_cap);
            test_scenario::return_shared(shop);
        };
    
        let tx = test_scenario::next_tx(scenario, shop_owner);
        let expected_events_emitted = 1;
        assert_eq(
            test_scenario::num_user_events(&tx),
            expected_events_emitted
        );

        test_scenario::next_tx(scenario, renter);
        {
            let shop = test_scenario::take_shared<Shop>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            let payment_coin = sui::coin::mint_for_testing<SUI>(
                expected_price, 
                test_scenario::ctx(scenario)
            );

            rent_item(
                &mut shop, 
                0,
                1,
                renter,
                payment_coin,
                &clock,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
            test_scenario::return_shared(shop);
        };
        test_scenario::end(scenario_val);
    }

    #[test]
    public fun test_return_item_success() {
        let shop_owner = @0xa;
        let renter = @0xb;

        let scenario_val = test_scenario::begin(shop_owner);
        let scenario = &mut scenario_val;

        {
            clock::share_for_testing(clock::create_for_testing(test_scenario::ctx(scenario)));
        };
        {
            create_shop(shop_owner, test_scenario::ctx(scenario));
        };
        
        test_scenario::next_tx(scenario, shop_owner);
        let expected_price = 1000; 
        {
            let shop_owner_cap  = test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop = test_scenario::take_shared<Shop>(scenario);

            add_item(
                &mut shop, 
                &shop_owner_cap,
                b"title", 
                b"description", 
                expected_price, 
                3,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, shop_owner_cap);
            test_scenario::return_shared(shop);
        };
        
        test_scenario::next_tx(scenario, renter);
        {
            let shop = test_scenario::take_shared<Shop>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            let payment_coin = sui::coin::mint_for_testing<SUI>(
                expected_price + DEPOSIT, 
                test_scenario::ctx(scenario)
            );

            rent_item(
                &mut shop, 
                0,
                1,
                renter,
                payment_coin,
                &clock,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
            test_scenario::return_shared(shop);
        };

        test_scenario::next_tx(scenario, renter);
        {
            let shop = test_scenario::take_shared<Shop>(scenario);
            let item = test_scenario::take_from_sender<Item>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            clock::increment_for_testing(&mut clock, 86000000);
            return_item(
                &mut shop, 
                item,
                &clock,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(shop);
            test_scenario::return_shared(clock);
        };

        test_scenario::next_tx(scenario, renter);
        {
            let coin = test_scenario::take_from_sender<coin::Coin<SUI>>(scenario);
            let shop = test_scenario::take_shared<Shop>(scenario);
            let in_store_item = table::borrow(&shop.items, 0);
            
            assert_eq(coin::value(&coin), DEPOSIT);
            assert_eq(balance::value(&shop.deposit), 0);
            assert_eq(in_store_item.listed, true);
            test_scenario::return_to_sender(scenario, coin);
            test_scenario::return_shared(shop);
        };

        test_scenario::end(scenario_val);
    }

    #[test, expected_failure(abort_code = EItemExpired)]
    public fun test_return_item_failure_expired() {
        let shop_owner = @0xa;
        let renter = @0xb;

        let scenario_val = test_scenario::begin(shop_owner);
        let scenario = &mut scenario_val;

        {
            clock::share_for_testing(clock::create_for_testing(test_scenario::ctx(scenario)));
        };
        {
            create_shop(shop_owner, test_scenario::ctx(scenario));
        };
        
        test_scenario::next_tx(scenario, shop_owner);
        let expected_price = 1000; 
        {
            let shop_owner_cap  = test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop = test_scenario::take_shared<Shop>(scenario);

            add_item(
                &mut shop, 
                &shop_owner_cap,
                b"title", 
                b"description", 
                expected_price, 
                3,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, shop_owner_cap);
            test_scenario::return_shared(shop);
        };
        
        test_scenario::next_tx(scenario, renter);
        {
            let shop = test_scenario::take_shared<Shop>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            let payment_coin = sui::coin::mint_for_testing<SUI>(
                expected_price + DEPOSIT, 
                test_scenario::ctx(scenario)
            );

            rent_item(
                &mut shop, 
                0,
                1,
                renter,
                payment_coin,
                &clock,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
            test_scenario::return_shared(shop);
        };

        test_scenario::next_tx(scenario, renter);
        {
            let shop = test_scenario::take_shared<Shop>(scenario);
            let item = test_scenario::take_from_sender<Item>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            clock::increment_for_testing(&mut clock, 87000000);
            return_item(
                &mut shop, 
                item,
                &clock,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(shop);
            test_scenario::return_shared(clock);
        };

        test_scenario::next_tx(scenario, renter);
        {
            let coin = test_scenario::take_from_sender<coin::Coin<SUI>>(scenario);
            let shop = test_scenario::take_shared<Shop>(scenario);
            assert_eq(coin::value(&coin), DEPOSIT);
            assert_eq(balance::value(&shop.deposit), 0);
            test_scenario::return_to_sender(scenario, coin);
            test_scenario::return_shared(shop);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    public fun test_unlist_item_success_unlist_item_with_no_purchases() {
        let shop_owner = @0xa;

        let scenario_val = test_scenario::begin(shop_owner);
        let scenario = &mut scenario_val;

        {
            clock::share_for_testing(clock::create_for_testing(test_scenario::ctx(scenario)));
        };
        {
            create_shop(shop_owner, test_scenario::ctx(scenario));
        };
        
        test_scenario::next_tx(scenario, shop_owner);
        let expected_price = 1000; 
        {
            let shop_owner_cap  = test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop = test_scenario::take_shared<Shop>(scenario);

            add_item(
                &mut shop, 
                &shop_owner_cap,
                b"title", 
                b"description", 
                expected_price, 
                3,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, shop_owner_cap);
            test_scenario::return_shared(shop);
        };

        test_scenario::next_tx(scenario, shop_owner);
        {
            let shop_owner_cap  = test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop = test_scenario::take_shared<Shop>(scenario);

            unlist_item(
                &mut shop,
                &shop_owner_cap,
                0
            );

            test_scenario::return_to_sender(scenario, shop_owner_cap);
            test_scenario::return_shared(shop);
        };
        
        test_scenario::end(scenario_val);
    }

    #[test, expected_failure(abort_code = ENotShopOwner)]
    public fun test_unlist_item_failure_wrong_shop_owner_cap() {
        let user1 = @0xa;
        let user2 = @0xb;

        let scenario_val = test_scenario::begin(user1);
        let scenario = &mut scenario_val;

        {
            create_shop(user2, test_scenario::ctx(scenario));
            create_shop(user1, test_scenario::ctx(scenario));
        };

        test_scenario::next_tx(scenario, user1);
        {
            let shop_owner_cap_of_user_1  = 
                test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop_of_user_1 = test_scenario::take_shared<Shop>(scenario);
            
            add_item(
                &mut shop_of_user_1, 
                &shop_owner_cap_of_user_1,
                b"title", 
                b"description", 
                1000, 
                3,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, shop_owner_cap_of_user_1);
            test_scenario::return_shared(shop_of_user_1);
        };

        test_scenario::next_tx(scenario, user2);
        {
            let shop_owner_cap_of_user_2  = 
                test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop_of_user_1 = test_scenario::take_shared<Shop>(scenario);
            let item_index = 0;

            unlist_item(
                &mut shop_of_user_1, 
                &shop_owner_cap_of_user_2,
                item_index
            );

            test_scenario::return_to_sender(scenario, shop_owner_cap_of_user_2);
            test_scenario::return_shared(shop_of_user_1);
        };
        test_scenario::end(scenario_val);
    }

    #[test]
    public fun test_withdraw_from_shop_success_withdraw_full_balance() {
        let shop_owner = @0xa;
        let renter = @0xb;

        let scenario_val = test_scenario::begin(shop_owner);
        let scenario = &mut scenario_val;

        {
            clock::share_for_testing(clock::create_for_testing(test_scenario::ctx(scenario)));
        };
        {
            create_shop(shop_owner, test_scenario::ctx(scenario));
        };

        test_scenario::next_tx(scenario, shop_owner);
        let expected_price = 1000; 
        {
            let shop_owner_cap  = test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop = test_scenario::take_shared<Shop>(scenario);

            add_item(
                &mut shop, 
                &shop_owner_cap,
                b"title", 
                b"description", 
                expected_price, 
                3,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, shop_owner_cap);
            test_scenario::return_shared(shop);
        };

        test_scenario::next_tx(scenario, renter);
        {
            let shop = test_scenario::take_shared<Shop>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            let payment_coin = sui::coin::mint_for_testing<SUI>(
                expected_price + DEPOSIT, 
                test_scenario::ctx(scenario)
            );

            rent_item(
                &mut shop, 
                0,
                1,
                renter,
                payment_coin,
                &clock,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
            test_scenario::return_shared(shop);
        };

        test_scenario::next_tx(scenario, shop_owner);
        {
            let shop_owner_cap  = test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop = test_scenario::take_shared<Shop>(scenario);

            let withdrawal_amount = balance::value(&shop.balance);

            withdraw_from_shop(
                &mut shop, 
                &shop_owner_cap,
                withdrawal_amount,
                shop_owner,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, shop_owner_cap);
            test_scenario::return_shared(shop);
        };

        let tx = test_scenario::next_tx(scenario, shop_owner);
        let expected_events_emitted = 1;
        assert_eq(
            test_scenario::num_user_events(&tx),
            expected_events_emitted
        );

        {
            let expected_shop_balance = 0;
            let shop = test_scenario::take_shared<Shop>(scenario);
            assert_eq(balance::value(&shop.balance), expected_shop_balance);

            test_scenario::return_shared(shop);
        };

        test_scenario::next_tx(scenario, shop_owner);
        {

            let expected_amount = 1000;
            let coin = test_scenario::take_from_sender<coin::Coin<SUI>>(scenario);
            assert_eq(coin::value(&coin), expected_amount);

            test_scenario::return_to_sender(scenario, coin);
        };
        test_scenario::end(scenario_val);

    }

    #[test]
    public fun test_withdraw_from_shop_success_withdraw_full_balance_with_overdue_deposit() {
        let shop_owner = @0xa;
        let renter = @0xb;

        let scenario_val = test_scenario::begin(shop_owner);
        let scenario = &mut scenario_val;

        {
            clock::share_for_testing(clock::create_for_testing(test_scenario::ctx(scenario)));
        };
        {
            create_shop(shop_owner, test_scenario::ctx(scenario));
        };

        test_scenario::next_tx(scenario, shop_owner);
        let expected_price = 1000; 
        {
            let shop_owner_cap  = test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop = test_scenario::take_shared<Shop>(scenario);

            add_item(
                &mut shop, 
                &shop_owner_cap,
                b"title", 
                b"description", 
                expected_price, 
                3,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, shop_owner_cap);
            test_scenario::return_shared(shop);
        };

        test_scenario::next_tx(scenario, renter);
        {
            let shop = test_scenario::take_shared<Shop>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            let payment_coin = sui::coin::mint_for_testing<SUI>(
                expected_price + DEPOSIT, 
                test_scenario::ctx(scenario)
            );

            rent_item(
                &mut shop, 
                0,
                1,
                renter,
                payment_coin,
                &clock,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
            test_scenario::return_shared(shop);
        };

        test_scenario::next_tx(scenario, shop_owner);
        {
            let shop_owner_cap  = test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop = test_scenario::take_shared<Shop>(scenario);
            let item = test_scenario::take_from_address<Item>(scenario, renter);
            let clock = test_scenario::take_shared<Clock>(scenario);
            clock::increment_for_testing(&mut clock, 86500000);
            item_expired(
                &mut shop, 
                &item,
                &clock,
                test_scenario::ctx(scenario)
            );

            let withdrawal_amount = balance::value(&shop.balance);
            withdraw_from_shop(
                &mut shop, 
                &shop_owner_cap,
                withdrawal_amount,
                shop_owner,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, shop_owner_cap);
            test_scenario::return_shared(shop);
            test_scenario::return_shared(clock);
            test_scenario::return_to_address(renter, item);
        };
        
        test_scenario::next_tx(scenario, shop_owner);
        {
            let expected_shop_balance = 0;
            let shop = test_scenario::take_shared<Shop>(scenario);
            assert_eq(balance::value(&shop.balance), expected_shop_balance);

            test_scenario::return_shared(shop);
        };

        test_scenario::next_tx(scenario, shop_owner);
        {

            let expected_amount = 1000 + DEPOSIT;
            let coin = test_scenario::take_from_sender<coin::Coin<SUI>>(scenario);
            assert_eq(coin::value(&coin), expected_amount);

            test_scenario::return_to_sender(scenario, coin);
        };
        test_scenario::end(scenario_val);

    }

    #[test]
    public fun test_withdraw_from_shop_success_withdraw_partial_balance() {
        let shop_owner = @0xa;
        let renter = @0xb;
        let recipient = @0xc;

        let scenario_val = test_scenario::begin(shop_owner);
        let scenario = &mut scenario_val;

        {
            clock::share_for_testing(clock::create_for_testing(test_scenario::ctx(scenario)));
        };
        {
            create_shop(shop_owner, test_scenario::ctx(scenario));
        };

        test_scenario::next_tx(scenario, shop_owner);
        let expected_price = 1000; 
        {
            let shop_owner_cap  = test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop = test_scenario::take_shared<Shop>(scenario);

            add_item(
                &mut shop, 
                &shop_owner_cap,
                b"title", 
                b"description", 
                expected_price, 
                3,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, shop_owner_cap);
            test_scenario::return_shared(shop);
        };

        test_scenario::next_tx(scenario, renter);
        {
            let shop = test_scenario::take_shared<Shop>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            let payment_coin = sui::coin::mint_for_testing<SUI>(
                expected_price + DEPOSIT, 
                test_scenario::ctx(scenario)
            );

            rent_item(
                &mut shop, 
                0,
                1,
                renter,
                payment_coin,
                &clock,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
            test_scenario::return_shared(shop);
        };

        test_scenario::next_tx(scenario, shop_owner);
        {
            let shop_owner_cap  = test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop = test_scenario::take_shared<Shop>(scenario);

            withdraw_from_shop(
                &mut shop, 
                &shop_owner_cap,
                500,
                recipient,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, shop_owner_cap);
            test_scenario::return_shared(shop);
        };

        let tx = test_scenario::next_tx(scenario, shop_owner);
        let expected_events_emitted = 1;
        assert_eq(
            test_scenario::num_user_events(&tx),
            expected_events_emitted
        );

        {
            let expected_amount_left_over = 500;
            let shop = test_scenario::take_shared<Shop>(scenario);
            assert_eq(
                balance::value(&shop.balance), expected_amount_left_over
            );

            test_scenario::return_shared(shop);
        };

        test_scenario::next_tx(scenario, recipient);
        {

            let expected_amount = 500;
            let coin = test_scenario::take_from_sender<coin::Coin<SUI>>(scenario);
            assert_eq(coin::value(&coin), expected_amount);

            test_scenario::return_to_sender(scenario, coin);
        };
        test_scenario::end(scenario_val);
    }

    #[test, expected_failure(abort_code = ENotShopOwner)]
    public fun test_withdraw_from_shop_failure_wrong_shop_owner_cap() {
        let user1 = @0xa;
        let user2 = @0xb;

        let scenario_val = test_scenario::begin(user1);
        let scenario = &mut scenario_val;

        {
            clock::share_for_testing(clock::create_for_testing(test_scenario::ctx(scenario)));
        };
        {
            create_shop(user2, test_scenario::ctx(scenario));
            create_shop(user1, test_scenario::ctx(scenario));
        };
        test_scenario::next_tx(scenario, user1);

        {
            let shop_owner_cap_of_user_1  = 
                test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop_of_user_1 = test_scenario::take_shared<Shop>(scenario);
            
            add_item(
                &mut shop_of_user_1, 
                &shop_owner_cap_of_user_1,
                b"title", 
                b"description", 
                1000, 
                3,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, shop_owner_cap_of_user_1);
            test_scenario::return_shared(shop_of_user_1);
        };
        test_scenario::next_tx(scenario, user2);

        {
            let shop_of_user_1 = test_scenario::take_shared<Shop>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);

            let item_index = 0;
            let item_ref = table::borrow(&shop_of_user_1.items, item_index);
            let price = item_ref.price;

            let payment_coin = coin::mint_for_testing<SUI>(
                price + DEPOSIT, 
                test_scenario::ctx(scenario)
            );

            rent_item(
                &mut shop_of_user_1, 
                0,
                1,
                user2,
                payment_coin,
                &clock,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(shop_of_user_1);
            test_scenario::return_shared(clock);
        };

        test_scenario::next_tx(scenario, user2);
        {
            let shop_owner_cap_of_user_2  = 
                test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop_of_user_1 = test_scenario::take_shared<Shop>(scenario);

            withdraw_from_shop(
                &mut shop_of_user_1, 
                &shop_owner_cap_of_user_2,
                1000,
                user1,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, shop_owner_cap_of_user_2);
            test_scenario::return_shared(shop_of_user_1);
        };
        test_scenario::end(scenario_val);
    }

    #[test, expected_failure(abort_code = EInvalidWithdrawalAmount)]
    public fun test_withdraw_from_shop_failure_amount_greater_than_balance() {
        let shop_owner = @0xa;
        let renter = @0xb;

        let scenario_val = test_scenario::begin(shop_owner);
        let scenario = &mut scenario_val;

        {
            clock::share_for_testing(clock::create_for_testing(test_scenario::ctx(scenario)));
        };
        {
            create_shop(shop_owner, test_scenario::ctx(scenario));
        };

        test_scenario::next_tx(scenario, shop_owner);

        let expected_price = 1000; 

        {
            let shop_owner_cap  = test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop = test_scenario::take_shared<Shop>(scenario);

            add_item(
                &mut shop, 
                &shop_owner_cap,
                b"title", 
                b"description", 
                expected_price, 
                3,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, shop_owner_cap);
            test_scenario::return_shared(shop);
        };

        test_scenario::next_tx(scenario, renter);
        {
            let shop = test_scenario::take_shared<Shop>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            let payment_coin = sui::coin::mint_for_testing<SUI>(
                expected_price + DEPOSIT, 
                test_scenario::ctx(scenario)
            );

            rent_item(
                &mut shop, 
                0,
                1,
                renter,
                payment_coin,
                &clock,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
            test_scenario::return_shared(shop);
        };

        test_scenario::next_tx(scenario, shop_owner);
        {
            let shop_owner_cap  = test_scenario::take_from_sender<ShopOwnerCapability>(scenario);
            let shop = test_scenario::take_shared<Shop>(scenario);

            withdraw_from_shop(
                &mut shop, 
                &shop_owner_cap,
                2000,
                shop_owner,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_to_sender(scenario, shop_owner_cap);
            test_scenario::return_shared(shop);
        };
        test_scenario::end(scenario_val);
    }
}

