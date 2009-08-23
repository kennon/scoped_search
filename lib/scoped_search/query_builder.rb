module ScopedSearch

  class QueryBuilder
    
    attr_reader :ast, :definition
    
    # Creates a find parameter hash given a class, and query string.
    def self.build_query(definition, query) 
      # Return all record when an empty search string is given
      if !query.kind_of?(String) || query.strip.blank?
        return { :conditions => nil }
      else
        builder = self.new(definition, ScopedSearch::QueryLanguage::Compiler.parse(query))
        return builder.build_find_params
      end
    end

    # Initializes the instance by setting the relevant parameters
    def initialize(definition, ast)
      @definition, @ast = definition, ast
    end
    
    # Actually builds the find parameters
    def build_find_params
      parameters = []
      sql = @ast.to_sql(definition) { |parameter| parameters << parameter }
      return { :conditions => [sql] + parameters }
    end
    
    # Return the SQL operator to use
    def self.sql_operator(operator)
      case operator
      when :eq;     '='  
      when :like;   'LIKE'              
      when :unlike; 'NOT LIKE'              
      when :ne;     '<>'  
      when :gt;     '>'
      when :lt;     '<'
      when :lte;    '<='
      when :gte;    '>='
      end  
    end
    
    # Generates a simple SQL test expression, for a field and value using an operator.
    def self.sql_test(field, operator, value, &block)
      if [:like, :unlike].include?(operator) && value !~ /^\%/ && value !~ /\%$/
        yield("%#{value}%")
      elsif field.temporal?
        timestamp = parse_temporal(value)
        return if timestamp.nil?
        yield(timestamp) 
      else
        yield(value)
      end
      "#{field.to_sql} #{self.sql_operator(operator)} ?"
    end
    
    def self.parse_temporal(value)
      Time.parse(value) rescue nil
    end

    module AST
      
      # Defines the to_sql method for AST LeadNodes
      module LeafNode
        def to_sql(definition, &block)
          # Search keywords found without context, just search on all the default fields
          fragments = definition.default_fields_for(value).map do |field|
            ScopedSearch::QueryBuilder.sql_test(field, field.default_operator, value, &block)
          end
          "(#{fragments.join(' OR ')})"
        end
      end
      
      # Defines the to_sql method for AST operator nodes
      module OperatorNode
            
        # Returns a NOT(...)  SQL fragment that negates the current AST node's children  
        def to_not_sql(definition, &block)
          "(NOT(#{rhs.to_sql(definition, &block)}) OR #{rhs.to_sql(definition, &block)} IS NULL)"
        end
        
        # No explicit field name given, run the operator on all default fields
        def to_default_fields_sql(definition, &block)
          raise ScopedSearch::Exception, "Value not a leaf node" unless rhs.kind_of?(ScopedSearch::QueryLanguage::AST::LeafNode)          
          
          # Search keywords found without context, just search on all the default fields
          fragments = definition.default_fields_for(rhs.value, operator).map do |field|
            ScopedSearch::QueryBuilder.sql_test(field, operator, rhs.value, &block)
          end
          "(#{fragments.join(' OR ')})"
        end
        
        # Explicit field name given, run the operator on the specified field only
        def to_single_field_sql(definition, &block)
          raise ScopedSearch::Exception, "Field name not a leaf node" unless lhs.kind_of?(ScopedSearch::QueryLanguage::AST::LeafNode)
          raise ScopedSearch::Exception, "Value not a leaf node"      unless rhs.kind_of?(ScopedSearch::QueryLanguage::AST::LeafNode)
          
          # Search only on the given field.
          field = definition.fields[lhs.value.to_sym]
          raise ScopedSearch::Exception, "Field '#{lhs.value}' not recognized for searching!" unless field
          ScopedSearch::QueryBuilder.sql_test(field, operator, rhs.value, &block)
        end
        
        # Convert this AST node to an SQL fragment.
        def to_sql(definition, &block)
          if operator == :not && children.length == 1
            to_not_sql(definition, &block)
          elsif children.length == 1
            to_default_fields_sql(definition, &block)            
          elsif children.length == 2
            to_single_field_sql(definition, &block)
          else
            raise ScopedSearch::Exception, "Don't know how to handle this operator node: #{operator.inspect} with #{children.inspect}!"
          end
        end 
      end
      
      # Defines the to_sql method for AST AND/OR operators
      module LogicalOperatorNode
        def to_sql(definition, &block)
          fragments = children.map { |c| c.to_sql(definition, &block) }
          "(#{fragments.join(" #{operator.to_s.upcase} ")})"
        end 
      end      
    end
  end

  QueryLanguage::AST::LeafNode.send(:include, QueryBuilder::AST::LeafNode)
  QueryLanguage::AST::OperatorNode.send(:include, QueryBuilder::AST::OperatorNode)
  QueryLanguage::AST::LogicalOperatorNode.send(:include, QueryBuilder::AST::LogicalOperatorNode)  
end
