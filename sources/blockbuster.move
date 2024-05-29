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
    const DEPOSIT: u64 = 10000000; // 10 SUI

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

    //==============================================================================================
    // Module Structs - DO NOT MODIFY
    //==============================================================================================
	struct Shop has key {
		id: UID,
        shop_owner_cap: ID,
		balance: Balance<SUI>,
        deposit: Balance<SUI>,
		items: Table<u64, InStoreItem>,
        item_count: u64,
        item_added_count: u64,
	}

    struct ShopOwnerCapability has key {
        id: UID,
        shop: ID,
    }

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

    struct ItemAdded has copy, drop {
        shop_id: ID,
        item_index: u64,
    }

    struct ItemRented has copy, drop {
        shop_id: ID,
        item_index: u64, 
        days: u64,
        renter: address,
    }

    struct ItemReturned has copy, drop {
        shop_id: ID,
        item_index: u64, 
        return_timestamp: u64,
        renter: address,
    }

    struct ItemExpired has copy, drop {
        shop_id: ID,
        item_index: u64, 
        renter: address,
    }

    struct ItemUnlisted has copy, drop {
        shop_id: ID,
        item_index: u64, 
    }

    struct ShopWithdrawal has copy, drop {
        shop_id: ID,
        amount: u64,
        recipient: address,
    }

    //==============================================================================================
    // Functions
    //==============================================================================================

    /// Creates a new shop for the recipient and emits a ShopCreated event.
    public fun create_shop(recipient: address, ctx: &mut TxContext) {
        let id = object::new(ctx);
        let shop_id = object::uid_to_inner(&id);
        let shop = Shop {
            id,
            shop_owner_cap: shop_id,
            balance: balance::zero(),
            deposit: balance::zero(),
            items: table::new<u64, InStoreItem>(ctx),
            item_count: 0,
            item_added_count: 0,
        };
        transfer::share_object(shop);
        let shop_owner_cap = ShopOwnerCapability {
            id: object::new(ctx),
            shop: shop_id,
        };
        transfer::transfer(shop_owner_cap, recipient);
    }

    /// Adds a new item to the shop and emits an ItemAdded event.
    public fun add_item(
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

    /// Unlists an item from the shop and emits an ItemUnlisted event.
    public fun unlist_item(
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

    /// Rent an item from the shop and emits an ItemRented event.
    public fun rent_item(
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
            title: item.title,
            description: item.description,
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

    /// Return an item to the shop and emits an ItemReturned event.
    public fun return_item(
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

    /// Removes an expired item from the shop and emits an ItemExpired event.
    public fun item_expired(
        shop: &mut Shop, 
        item: &Item,
        clock: &Clock,
        _: &mut TxContext
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

    /// Withdraws SUI from the shop to the recipient and emits a ShopWithdrawal event.
    public fun withdraw_from_shop(
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
        let Item { id, .. } = nft;
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

    /// Lists an item that was previously unlisted.
    public fun list_item(
        shop: &mut Shop,
        shop_owner_cap: &ShopOwnerCapability,
        item_index: u64
    ) {
        let shop_id = sui::object::uid_to_inner(&shop.id);
        assert_shop_owner(shop_owner_cap.shop, shop_id);
        assert_item_index_valid(item_index, &shop.items);

        let item = table::borrow_mut(&mut shop.items, item_index);
        item.listed = true;
        shop.item_count = shop.item_count + 1;
    }

    /// Retrieve the details of the shop.
    public fun get_shop_details(shop: &Shop): (u64, u64, u64, u64) {
        let balance = balance::value(&shop.balance);
        let deposit = balance::value(&shop.deposit);
        (shop.item_count, shop.item_added_count, balance, deposit)
    }

    /// Get total items in the shop.
    public fun get_total_items(shop: &Shop): u64 {
        shop.item_count
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
            let inStoreItem = table::borrow(&shop.items, 0);

            assert_eq(item.price, expected_price);
            assert_eq(balance::value(&shop.balance), item.price);
            assert_eq(item.renter, renter);
            assert_eq(item.expiry, 86400000);
            assert_eq(inStoreItem.listed, false);

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
        public fun test_rent_item_failure(){
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
            let inStoreItem = table::borrow(&shop.items, 0);

            assert_eq(item.price, expected_price);
            assert_eq(balance::value(&shop.balance), item.price);
            assert_eq(item.renter, renter);
            assert_eq(item.expiry, clock::timestamp_ms(&clock) + 86400000);
            assert_eq(inStoreItem.listed, false);

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

    test_scenario::return_shared(clock);
        test_scenario::return_shared(shop);
    };

}
