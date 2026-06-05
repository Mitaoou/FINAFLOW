  import 'package:flutter/material.dart';
  import 'package:supabase_flutter/supabase_flutter.dart';
  import 'package:intl/intl.dart';
  import '../models/transaction_model.dart';
  import '../models/budget_model.dart';
  import '../models/project_model.dart';
  import '../widgets/error_formatter.dart';

  class FinanceProvider extends ChangeNotifier {
    final List<TransactionModel> _transactions = [];
    final List<BudgetModel> _budgets = [];
    List<TransactionCategory> _categories = [];
    List<ProjectModel> _projects = [];

    bool _isLoggedIn = false;
    String _userName = '';
    String _userEmail = '';
    bool _isLoading = false;
    String? _errorMessage;

    bool get isLoggedIn => _isLoggedIn;
    String get userName => _userName;
    String get userEmail => _userEmail;
    bool get isLoading => _isLoading;
    String? get errorMessage => _errorMessage;

    List<TransactionModel> get transactions {
      final sorted = _transactions.toList()
        ..sort((a, b) => b.date.compareTo(a.date));
      return List.unmodifiable(sorted);
    }

    List<BudgetModel> get budgets => List.unmodifiable(_budgets);
    List<TransactionCategory> get categories => List.unmodifiable(_categories);
    List<ProjectModel> get projects => List.unmodifiable(_projects);

    // ─── Auth ───────────────────────────────────────────────────────────────

    Future<void> initializeUserSession() async {
      final session = Supabase.instance.client.auth.currentSession;
      if (session != null) {
        _isLoggedIn = true;
        _userEmail = session.user.email ?? '';
        await fetchAllData();
      }
    }

    Future<bool> login(String email, String password) async {
      _isLoading = true;
      _errorMessage = null;
      notifyListeners();



      try {
        final response = await Supabase.instance.client.auth.signInWithPassword(
          email: email,
          password: password,
        );

        if (response.session != null) {
          _isLoggedIn = true;
          _userEmail = email;
          await fetchAllData();
          return true;
        }
        return false;
      } catch (e) {
        _errorMessage = ErrorFormatter.format(e);
        debugPrint('Supabase login error: $e');
        return false;
      } finally {
        _isLoading = false;
        notifyListeners();
      }
    }

    Future<bool> register(String name, String email, String password) async {
      _isLoading = true;
      _errorMessage = null;
      notifyListeners();

      try {
        final response = await Supabase.instance.client.auth.signUp(
          email: email,
          password: password,
          data: {'nama_user': name},
        );

        final user = response.user;
        if (user != null) {


          _isLoggedIn = true;
          _userEmail = email;
          _userName = name;
          
          await fetchAllData();
          return true;
        }
        return false;
      } catch (e) {
        _errorMessage = ErrorFormatter.format(e);
        debugPrint('Supabase register error: $e');
        return false;
      } finally {
        _isLoading = false;
        notifyListeners();
      }
    }

    Future<void> logout() async {
      try {
        await Supabase.instance.client.auth.signOut();
      } catch (e) {
        debugPrint('Signout error: $e');
      }
      _isLoggedIn = false;
      _userName = '';
      _userEmail = '';
      _transactions.clear();
      _budgets.clear();
      _categories.clear();
      _projects.clear();
      notifyListeners();
    }



    // ─── Fetch All Data ───────────────────────────────────────────────────────

    Future<void> fetchAllData() async {


      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return;

      try {
        // 1. Ambil Profile
        final profileData = await Supabase.instance.client
            .from('profiles')
            .select()
            .eq('id', userId)
            .maybeSingle();
        
        if (profileData != null) {
          _userName = profileData['nama_user'] ?? _userEmail.split('@').first;
        } else {
          _userName = _userEmail.split('@').first;
        }

        // 2. Ambil Kategori
        final categoriesData = await Supabase.instance.client
            .from('kategori')
            .select()
            .eq('user_id', userId);
        
        _categories = (categoriesData as List)
            .map((row) => Categories.fromSupabase(row))
            .toList();



        // Set registry statis Categories agar findById() bekerja di UI
        Categories.setCategories(_categories);

        // 3. Ambil Proyek
        final projectsData = await Supabase.instance.client
            .from('proyek')
            .select()
            .eq('user_id', userId);
        
        _projects = (projectsData as List)
            .map((row) => ProjectModel.fromSupabase(row))
            .toList();

        // 4. Ambil Transaksi (relational nested query)
        final transactionsData = await Supabase.instance.client
            .from('transaksi')
            .select('*, kategori(*), proyek(*)')
            .eq('user_id', userId)
            .order('tanggal', ascending: false);
        
        _transactions.clear();
        _transactions.addAll((transactionsData as List)
            .map((row) => TransactionModel.fromSupabase(row))
            .toList());

        // 5. Ambil Anggaran
        final budgetsData = await Supabase.instance.client
            .from('anggaran')
            .select('*, kategori(*)')
            .eq('user_id', userId);

        _budgets.clear();
        for (var row in budgetsData as List) {
          final categoryId = row['id_kategori'].toString();
          
          // Hitung total terpakai (spent) dinamis dari transaksi bulan ini
          final totalSpent = _transactions
              .where((t) =>
                  t.categoryId == categoryId &&
                  t.type == TransactionType.expense &&
                  t.date.month == DateTime.now().month &&
                  t.date.year == DateTime.now().year)
              .fold(0.0, (sum, t) => sum + t.amount);

          _budgets.add(BudgetModel.fromSupabase(row, totalSpent));
        }

        _errorMessage = null;
      } catch (e) {
        _errorMessage = ErrorFormatter.format(e);
        debugPrint('Error fetching data from Supabase: $e');
      } finally {
        notifyListeners();
      }
    }

    // ─── Transactions ────────────────────────────────────────────────────────



    Future<void> addTransactionSupabase(
        String title,
        double amount,
        TransactionType type,
        String categoryId,
        DateTime date,
        String? note,
        String? projectId) async {
      _isLoading = true;
      _errorMessage = null;
      notifyListeners();

      try {


        final userId = Supabase.instance.client.auth.currentUser?.id;
        if (userId == null) throw Exception('User not logged in');

        // Menggabungkan judul & catatan ke deskripsi jika catatan tidak kosong
        final deskripsi = note != null && note.isNotEmpty ? '$title\n$note' : title;

        await Supabase.instance.client.from('transaksi').insert({
          'user_id': userId,
          'id_kategori': int.parse(categoryId),
          'id_proyek': projectId != null ? int.parse(projectId) : null,
          'tanggal': DateFormat('yyyy-MM-dd').format(date),
          'nominal': amount,
          'deskripsi': deskripsi,
        });

        await fetchAllData();
      } catch (e) {
        _errorMessage = ErrorFormatter.format(e);
        debugPrint('Error adding transaction: $e');
        rethrow;
      } finally {
        _isLoading = false;
        notifyListeners();
      }
    }

    void addTransaction(TransactionModel tx) {
      addTransactionSupabase(
        tx.title,
        tx.amount,
        tx.type,
        tx.categoryId,
        tx.date,
        tx.note,
        tx.projectId,
      );
    }

    Future<void> deleteTransactionSupabase(String id) async {
      _isLoading = true;
      _errorMessage = null;
      notifyListeners();

      try {


        await Supabase.instance.client
            .from('transaksi')
            .delete()
            .eq('id_transaksi', int.parse(id));

        await fetchAllData();
      } catch (e) {
        _errorMessage = ErrorFormatter.format(e);
        debugPrint('Error deleting transaction: $e');
        rethrow;
      } finally {
        _isLoading = false;
        notifyListeners();
      }
    }

    void deleteTransaction(String id) {
      deleteTransactionSupabase(id);
    }

    // ─── Budget ──────────────────────────────────────────────────────────────

    Future<void> addBudgetSupabase(String categoryId, double limit) async {
      _isLoading = true;
      _errorMessage = null;
      notifyListeners();

      try {


        final userId = Supabase.instance.client.auth.currentUser?.id;
        if (userId == null) throw Exception('User not logged in');

        final now = DateTime.now();
        final firstDayOfMonth = DateTime(now.year, now.month, 1);

        await Supabase.instance.client.from('anggaran').insert({
          'user_id': userId,
          'id_kategori': int.parse(categoryId),
          'batas_nominal': limit,
          'periode_bulan': DateFormat('yyyy-MM-dd').format(firstDayOfMonth),
        });

        await fetchAllData();
      } catch (e) {
        _errorMessage = ErrorFormatter.format(e);
        debugPrint('Error adding budget: $e');
        rethrow;
      } finally {
        _isLoading = false;
        notifyListeners();
      }
    }

    void addBudget(BudgetModel budget) {
      addBudgetSupabase(budget.categoryId, budget.limit);
    }

    Future<void> updateBudgetSupabase(String id, String categoryId, double limit) async {
      _isLoading = true;
      _errorMessage = null;
      notifyListeners();

      try {


        await Supabase.instance.client.from('anggaran').update({
          'id_kategori': int.parse(categoryId),
          'batas_nominal': limit,
        }).eq('id_anggaran', int.parse(id));

        await fetchAllData();
      } catch (e) {
        _errorMessage = ErrorFormatter.format(e);
        debugPrint('Error updating budget: $e');
        rethrow;
      } finally {
        _isLoading = false;
        notifyListeners();
      }
    }

    void updateBudget(BudgetModel updated) {
      updateBudgetSupabase(updated.id, updated.categoryId, updated.limit);
    }

    Future<void> deleteBudgetSupabase(String id) async {
      _isLoading = true;
      _errorMessage = null;
      notifyListeners();

      try {


        await Supabase.instance.client
            .from('anggaran')
            .delete()
            .eq('id_anggaran', int.parse(id));

        await fetchAllData();
      } catch (e) {
        _errorMessage = ErrorFormatter.format(e);
        debugPrint('Error deleting budget: $e');
        rethrow;
      } finally {
        _isLoading = false;
        notifyListeners();
      }
    }

    void deleteBudget(String id) {
      deleteBudgetSupabase(id);
    }

    List<BudgetModel> get warningBudgets =>
        _budgets.where((b) => b.isWarning || b.isExceeded).toList();

    // ─── Custom Category / Project CRUD ──────────────────────────────────────────

    Future<void> addCategory(String name, TransactionType type) async {
      _isLoading = true;
      _errorMessage = null;
      notifyListeners();

      try {


        final userId = Supabase.instance.client.auth.currentUser?.id;
        if (userId == null) throw Exception('User not logged in');

        final jenis = type == TransactionType.income ? 'pemasukan' : 'pengeluaran';

        await Supabase.instance.client.from('kategori').insert({
          'user_id': userId,
          'nama_kategori': name,
          'jenis_kategori': jenis,
        });

        await fetchAllData();
      } catch (e) {
        _errorMessage = ErrorFormatter.format(e);
        debugPrint('Error adding custom category: $e');
        rethrow;
      } finally {
        _isLoading = false;
        notifyListeners();
      }
    }

    Future<void> addProject(String name, String tag, String? description) async {
      _isLoading = true;
      _errorMessage = null;
      notifyListeners();

      try {


        final userId = Supabase.instance.client.auth.currentUser?.id;
        if (userId == null) throw Exception('User not logged in');

        await Supabase.instance.client.from('proyek').insert({
          'user_id': userId,
          'nama_proyek': name,
          'tag_proyek': tag,
          'keterangan': description,
        });

        await fetchAllData();
      } catch (e) {
        _errorMessage = ErrorFormatter.format(e);
        debugPrint('Error adding project: $e');
        rethrow;
      } finally {
        _isLoading = false;
        notifyListeners();
      }
    }

    // ─── Summary / Analytics ─────────────────────────────────────────────────

    double get totalIncome => _transactions
        .where((t) => t.type == TransactionType.income)
        .fold(0.0, (sum, t) => sum + t.amount);

    double get totalExpense => _transactions
        .where((t) => t.type == TransactionType.expense)
        .fold(0.0, (sum, t) => sum + t.amount);

    double get netBalance => totalIncome - totalExpense;

    double get monthlyIncome {
      final now = DateTime.now();
      return _transactions
          .where((t) =>
              t.type == TransactionType.income &&
              t.date.month == now.month &&
              t.date.year == now.year)
          .fold(0.0, (sum, t) => sum + t.amount);
    }

    double get monthlyExpense {
      final now = DateTime.now();
      return _transactions
          .where((t) =>
              t.type == TransactionType.expense &&
              t.date.month == now.month &&
              t.date.year == now.year)
          .fold(0.0, (sum, t) => sum + t.amount);
    }

    // Data 6 bulan terakhir untuk line chart
    List<Map<String, dynamic>> getLast6MonthsData() {
      final now = DateTime.now();
      final result = <Map<String, dynamic>>[];

      for (int i = 5; i >= 0; i--) {
        final month = DateTime(now.year, now.month - i, 1);
        final income = _transactions
            .where((t) =>
                t.type == TransactionType.income &&
                t.date.month == month.month &&
                t.date.year == month.year)
            .fold(0.0, (sum, t) => sum + t.amount);
        final expense = _transactions
            .where((t) =>
                t.type == TransactionType.expense &&
                t.date.month == month.month &&
                t.date.year == month.year)
            .fold(0.0, (sum, t) => sum + t.amount);

        result.add({
          'month': month,
          'income': income,
          'expense': expense,
        });
      }
      return result;
    }

    // Data pengeluaran per kategori untuk pie chart
    Map<String, double> getExpenseByCategory() {
      final Map<String, double> result = {};
      for (final tx
          in _transactions.where((t) => t.type == TransactionType.expense)) {
        result[tx.categoryId] = (result[tx.categoryId] ?? 0) + tx.amount;
      }
      return result;
    }

    // Transaksi terbaru
    List<TransactionModel> get recentTransactions =>
        transactions.take(5).toList();
  }
