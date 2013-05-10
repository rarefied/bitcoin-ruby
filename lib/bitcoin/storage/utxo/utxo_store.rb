Bitcoin.require_dependency :sequel, message:
  "Note: You will also need an adapter for your database like sqlite3, mysql2, postgresql"
require_relative 'migrations'

module Bitcoin::Storage::Backends

  # Storage backend using Sequel to connect to arbitrary SQL databases.
  # Inherits from StoreBase and implements its interface.
  class UtxoStore < StoreBase


    # possible script types
    SCRIPT_TYPES = [:unknown, :pubkey, :hash160, :multisig, :p2sh]
    if Bitcoin.namecoin?
      [:name_new, :name_firstupdate, :name_update].each {|n| SCRIPT_TYPES << n }
    end

    # sequel database connection
    attr_accessor :db

    include Bitcoin::Storage::Backends::UtxoMigrations

    DEFAULT_CONFIG = { cache_head: false, utxo_cache: 5000,
      journal_mode: false, synchronous: false, cache_size: -200_000 }

    # create sequel store with given +config+
    def initialize config, *args
      @utxo, @tx_cache, @spent_outs, @new_outs = {}, {}, [], []
      super config, *args
      @config = DEFAULT_CONFIG.merge(@config)
      log.level = @config[:log_level]  if @config[:log_level]
      connect
    end

    # connect to database
    def connect
      {:sqlite => "sqlite3", :postgres => "pg", :mysql => "mysql",
      }.each do |adapter, name|
        if @config[:db].split(":").first == adapter.to_s
          Bitcoin.require_dependency name, gem: name
          @db = Sequel.connect(@config[:db])
          if name == "sqlite3" #@db.is_a?(Sequel::SQLite::Database)
            [:journal_mode, :synchronous, :cache_size].each do |pragma|
              @db.pragma_set pragma, @config[pragma]
              log.debug { "set sqlite pragma #{pragma} to #{@config[pragma]}" }
            end
          end
        end
      end
      migrate
    end

    # reset database; delete all data
    def reset
      [:blk, :utxo].each {|table| @db[table].delete }
      @head = nil
    end

    def flush
      flush_spent_outs; flush_new_outs
    end

    def flush_spent_outs
      log.time "flushed #{@spent_outs.size} spent txouts in %.4fs" do
        if @spent_outs.any?
          spent = @db[:utxo].where(@spent_outs.shift)
          @spent_outs.each {|o| spent = spent.or(o) }
        end
        @spent_outs = []
      end
    end

    def flush_new_outs
      log.time "flushed #{@new_outs.size} new txouts in %.4fs" do
        @db[:utxo].insert_multiple(@new_outs)
        @new_outs = []
      end
    end

    # persist given block +blk+ to storage.
    def persist_block blk, chain, depth, prev_work = 0
      @db.transaction do
        attrs = {
          :hash => blk.hash.htb.to_sequel_blob,
          :depth => depth,
          :chain => chain,
          :version => blk.ver,
          :prev_hash => blk.prev_block.reverse.to_sequel_blob,
          :mrkl_root => blk.mrkl_root.reverse.to_sequel_blob,
          :time => blk.time,
          :bits => blk.bits,
          :nonce => blk.nonce,
          :blk_size => blk.to_payload.bytesize,
          :work => (prev_work + blk.block_work).to_s
        }
        existing = @db[:blk].filter(:hash => blk.hash.htb.to_sequel_blob)
        if existing.any?
          existing.update attrs
          block_id = existing.first[:id]
        else
          block_id = @db[:blk].insert(attrs)

          blk.tx.each.with_index do |tx, tx_blk_idx|

            tx.in.each.with_index do |txin, txin_tx_idx|
              next  if txin.coinbase?
              @spent_outs << {
                tx_hash: txin.prev_out.reverse.to_sequel_blob,
                tx_idx: txin.prev_out_index  }
            end

            tx.out.each.with_index do |txout, txout_tx_idx|
              @new_outs << {
                :tx_hash => tx.hash.htb.to_sequel_blob,
                :tx_idx => txout_tx_idx,
                :blk_id => block_id,
                :pk_script => txout.pk_script.to_sequel_blob,
                :value => txout.value }
            end
          end

          if in_sync?
            flush
          else
            flush_spent_outs  if @spent_outs.size > @config[:utxo_cache]
            flush_new_outs  if @new_outs.size > @config[:utxo_cache]
          end

          @tx_cache = {}
          @head = wrap_block(attrs.merge(id: block_id))  if chain == MAIN
        end

        return depth, chain
      end
    end

    # check if block +blk_hash+ exists
    def has_block(blk_hash)
      !!@db[:blk].where(:hash => blk_hash.htb.to_sequel_blob).get(1)
    end

    # check if transaction +tx_hash+ exists
    def has_tx(tx_hash)
      !!@db[:utxo].where(:hash => tx_hash.htb.to_sequel_blob).get(1)
    end

    # get head block (highest block from the MAIN chain)
    def get_head
      (@config[:cache_head] && @head) ? @head :
        @head = wrap_block(@db[:blk].filter(:chain => MAIN).order(:depth).last)
    end

    # get depth of MAIN chain
    def get_depth
      return -1  unless get_head
      get_head.depth
    end

    # get block for given +blk_hash+
    def get_block(blk_hash)
      wrap_block(@db[:blk][:hash => blk_hash.htb.to_sequel_blob])
    end

    # get block by given +depth+
    def get_block_by_depth(depth)
      wrap_block(@db[:blk][:depth => depth, :chain => MAIN])
    end

    # get block by given +prev_hash+
    def get_block_by_prev_hash(prev_hash)
      wrap_block(@db[:blk][:prev_hash => prev_hash.htb.to_sequel_blob, :chain => MAIN])
    end

    # get block by given +tx_hash+
    def get_block_by_tx(tx_hash)
      block_id = @db[:utxo][tx_hash: tx_hash.htb.to_sequel_blob][:blk_id]
      get_block_by_id(block_id)
    end

    # get block by given +id+
    def get_block_by_id(block_id)
      wrap_block(@db[:blk][:id => block_id])
    end

    # get transaction for given +tx_hash+
    def get_tx(tx_hash)
      @tx_cache[tx_hash] ||= wrap_tx(tx_hash)
    end

    # get transaction by given +tx_id+
    def get_tx_by_id(tx_id)
      get_tx(tx_id)
    end

    # get corresponding Models::TxOut for +txin+
    def get_txout_for_txin(txin)
      tx = @db[:tx][:hash => txin.prev_out.reverse.to_sequel_blob]
      return nil  unless tx
      wrap_txout(@db[:txout][:tx_idx => txin.prev_out_index, :tx_id => tx[:id]])
    end

    # get all Models::TxOut matching given +script+
    def get_txouts_for_pk_script(script)
      utxos = @db[:utxo].filter(pk_script: script.to_sequel_blob).order(:blk_id)
      utxos.map {|utxo| wrap_txout(utxo) }
    end

    # get all Models::TxOut matching given +hash160+
    def get_txouts_for_hash160(hash160, unconfirmed = false)
      get_txouts_for_pk_script(Script.to_hash160_script(hash160))
    end

    # wrap given +block+ into Models::Block
    def wrap_block(block)
      return nil  unless block

      data = {:id => block[:id], :depth => block[:depth], :chain => block[:chain],
        :work => block[:work].to_i, :hash => block[:hash].hth}
      blk = Bitcoin::Storage::Models::Block.new(self, data)

      blk.ver = block[:version]
      blk.prev_block = block[:prev_hash].reverse
      blk.mrkl_root = block[:mrkl_root].reverse
      blk.time = block[:time].to_i
      blk.bits = block[:bits]
      blk.nonce = block[:nonce]

      blk.recalc_block_hash
      blk
    end

    # wrap given +transaction+ into Models::Transaction
    def wrap_tx(tx_hash)
      utxos = @db[:utxo].where(tx_hash: tx_hash.htb.to_sequel_blob)
      return nil  unless utxos.any?
      data = { blk_id: utxos.first[:blk_id] }
      tx = Bitcoin::Storage::Models::Tx.new(self, data)
      tx.hash = tx_hash # utxos.first[:tx_hash].hth
      utxos.each {|u| tx.out[u[:tx_idx]] = wrap_txout(u) }
      return tx
    end

    # wrap given +output+ into Models::TxOut
    def wrap_txout(utxo)
      data = {tx_id: utxo[:tx_hash].hth, tx_idx: utxo[:tx_idx]}
      txout = Bitcoin::Storage::Models::TxOut.new(self, data)
      txout.value = utxo[:value]
      txout.pk_script = utxo[:pk_script]
      txout
    end

    def get_txouts_for_name_hash(hash)
      name_new_pattern = "Q\x14#{hash.htb}mv\xa9\x14%"
      @db[:utxo].filter("pk_script LIKE ?", name_new_pattern.to_sequel_blob).map {|o|
        wrap_txout(o) }
    end

    def get_txouts_for_name(name)
      name_firstupdate_pattern = "R\x04#{name}%mmv\xa9\x14%"
      name_update_pattern = "S\x04#{name}%muv\xa9\x14%"
      @db[:utxo].filter("pk_script LIKE ?", name_firstupdate_pattern.to_sequel_blob)
       .or("pk_script LIKE ?", name_update_pattern.to_sequel_blob).sort_by {|o| o[:blk_id] }
    end

    def name_show(name)
      wrap_name(get_txouts_for_name(name).last)
    end

    def wrap_name txout
      return nil  unless txout
      script = Bitcoin::Script.new(txout[:pk_script])
      data = { txout_id: [txout[:tx_hash].hth, txout[:tx_idx]],
        hash: script.get_namecoin_hash,
        name: script.get_namecoin_name,
        value: script.get_namecoin_value }
      Bitcoin::Storage::Models::Name.new(self, data)

    end

  end

end
